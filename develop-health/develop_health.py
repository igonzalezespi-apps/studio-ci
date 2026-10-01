#!/usr/bin/env python3
"""develop_health.py — watch the integration branch and undo an automatic merge that turned it red.

It always judges the CURRENT head of the integration branch with the push checks the repo requires
(`required_push_checks`), then:

  green               close (or, if escalated, just unfreeze) the freeze it opened
  pending / no runs   nothing; a head with no push run for 60 minutes is reported as stalled
  infrastructure red  never revert: a job that never ran (0 steps, no runner, cancelled,
                      startup_failure) is not the code's fault. Re-run it once.
  real red, attempt 1 re-run the failed jobs once (a flaky test is not a culprit)
  real red, again     freeze automatic merging (an issue labelled merge-freeze) and attribute:
                      L = the newest pushed commit whose push checks are green, F = the FIRST red
                      push after L. F is reverted automatically only if ALL hold:
                        * L...F is exactly one commit, F, with one parent (a squash);
                        * F is the merge commit of a PR merged BY THE MERGE APP;
                        * F's message carries `Risk-class: riesgo:0..2` (the commit, not a label
                          anybody can change afterwards: the last such line, followed by the
                          gate's `Merge-gate:` line);
                        * F is not itself a revert;
                        * fewer than `max_reverts_per_day` reverts in the last 24 h;
                        * no revert of that PR exists yet.
                      Otherwise it escalates: the freeze issue gets revision-humana and a TL;DR.
                      A person's merge is never reverted automatically.
                      While the revert is open it is re-judged on every run with merge-when-green's
                      own rules: closed without merging, invalid (anything pushed on top of it),
                      red, in conflict, or open for more than REVERT_STALE_MINUTES → escalate.
  green after a freeze  lift it, and close the App's reverts still open (a fix went in first).

    develop-health.sh --repo R --mode dry|live --plan F [--repo-dir D] [--run-url U]

In dry mode it only writes the job summary and one comment on the culprit PR; with
--selftest-config (this repository's own CI) it writes nothing at all. Exit 0 whenever it measured
(a red develop is a finding, not a failure of this job) · 2 could not measure.
"""
import json
import os
import re
import sys
from urllib.parse import quote

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "merge-when-green"))
sys.path.insert(0, os.path.join(HERE, "..", "risk-class"))
import mwg  # noqa: E402
import ci_verdict  # noqa: E402
import pr_merge  # noqa: E402

FREEZE_MARK = "<!-- develop-health v1 freeze -->"
CULPRIT_MARK = "<!-- develop-health v1 culprit"
MAX_PUSHES = 20
STALL_MINUTES = 60
REVERT_STALE_MINUTES = 120


def push_history(gh, repo, branch):
    """Pushed commits of the branch, newest first, each with its push runs."""
    runs = gh.list("repos/%s/actions/runs?branch=%s&event=push" % (repo, quote(branch, safe="")),
                   key="workflow_runs", max_pages=2)
    by_sha = {}
    for r in runs:
        if r.get("head_branch") != branch or r.get("event") != "push":
            continue
        by_sha.setdefault(r["head_sha"], []).append(r)
    order = sorted(by_sha, key=lambda s: min(r.get("created_at") or "" for r in by_sha[s]), reverse=True)
    return order[:MAX_PUSHES], by_sha


def judge(gh, repo, runs, required):
    for r in runs:
        if "_jobs" not in r:
            r["_jobs"] = gh.list("repos/%s/actions/runs/%d/jobs?filter=all" % (repo, r["id"]), key="jobs")
    v = ci_verdict.verdict(runs, required, settle=0)
    v["health"] = ci_verdict.required_verdict(v)
    req = {(e["workflow"], e["job"]) for e in required}
    bad_jobs = []
    for r in runs:
        wf = ci_verdict._wf(r.get("path"))
        latest = {}
        for j in r["_jobs"]:
            k = (wf, j.get("name"))
            if k in req and (k not in latest or ci_verdict.attempt_rank(j, int(j.get("run_attempt") or 1)) >=
                             ci_verdict.attempt_rank(latest[k], int(latest[k].get("run_attempt") or 1))):
                latest[k] = j
        for k, j in latest.items():
            if ci_verdict._job_state(j)[0] == "bad":
                bad_jobs.append((r, j))
    infra = bool(bad_jobs) and all(ci_verdict.infra_failure(j) for _, j in bad_jobs)
    attempts = max([int(r.get("run_attempt") or 1) for r, _ in bad_jobs] or [1])
    return v, bad_jobs, infra, attempts


def freeze_issue(gh, repo):
    issues = gh.list("repos/%s/issues?state=open&labels=%s" % (repo, pr_merge.FREEZE_LABEL))
    for i in issues:
        if "pull_request" in i:
            continue
        if (i.get("user") or {}).get("login") == pr_merge.ACTIONS_BOT and FREEZE_MARK in (i.get("body") or ""):
            return i
    return None


def recent_reverts(gh, repo, app):
    pulls = gh.list("repos/%s/pulls?state=all&sort=created&direction=desc" % repo, max_pages=1, per_page=50)
    out = []
    for p in pulls:
        if (p.get("user") or {}).get("login") != app:
            continue
        m = pr_merge.REVERT_MARK_RX.search(p.get("body") or "")
        if m and (p.get("head", {}).get("repo") or {}).get("full_name") == repo:
            out.append({"number": p["number"], "of": int(m.group(1)), "created_at": p.get("created_at"),
                        "state": p.get("state"), "merged_at": p.get("merged_at")})
    return out


def attribute(gh, repo, ctx, order, by_sha, head_sha):
    """(culprit-dict | None, reasons-to-escalate)."""
    required = ctx.cfg["required_push_checks"]
    verdicts, idx_l = {}, None
    for i, sha in enumerate(order):  # newest first; stop at the first green (L)
        v, _, infra, _ = judge(gh, repo, by_sha[sha], required)
        verdicts[sha] = "infra" if (v["health"] == "red" and infra) else v["health"]
        if verdicts[sha] == "green":
            idx_l = i
            break
    if idx_l is None:
        return None, ["no green push in the last %d pushes of %s" % (len(order), ctx.integration)], {}
    last_green = order[idx_l]
    newer = order[:idx_l]
    reds = [s for s in newer if verdicts[s] == "red"]
    if not reds:
        return None, ["the red at %s could not be tied to a pushed commit" % head_sha[:7]], {}
    first_red = reds[-1]
    cmp = gh.get("repos/%s/compare/%s...%s" % (repo, last_green, first_red))
    commits = cmp.get("commits") or []
    info = {"last_green": last_green, "first_red": first_red, "range": [c["sha"] for c in commits]}
    if cmp.get("behind_by") or len(commits) != 1 or commits[0]["sha"] != first_red:
        return None, ["%d commits between the last green (%s) and the first red (%s): not attributable to one merge"
                      % (len(commits), last_green[:7], first_red[:7])], info
    c = commits[0]
    if len(c.get("parents") or []) != 1:
        return None, ["%s is a merge commit, not a squash" % first_red[:7]], info
    msg = (c.get("commit") or {}).get("message") or ""
    pulls = gh.list("repos/%s/commits/%s/pulls" % (repo, first_red))
    pr = next((p for p in pulls if p.get("merge_commit_sha") == first_red and p.get("merged_at")), None)
    if not pr:
        return None, ["%s does not belong to a merged pull request" % first_red[:7]], info
    info["pr"] = pr["number"]
    info["pr_title"] = pr.get("title") or ""
    app = pr_merge.bot_login(ctx.cfg.get("app_slug"))
    if not app or (pr.get("merged_by") or {}).get("login") != app:
        return None, ["#%d was merged by %s, not by the merge App: a person's merge is never reverted "
                      "automatically" % (pr["number"], (pr.get("merged_by") or {}).get("login") or "?")], info
    t = pr_merge.trailer_class(msg)
    if t is None or t > 2:
        return None, ["%s carries no Risk-class riesgo:0..2 trailer" % first_red[:7]], info
    info["class"] = t
    labels = [lb["name"] for lb in pr.get("labels") or []]
    if pr_merge.REVERT_LABEL in labels or (pr.get("title") or "").lower().startswith("revert") or \
            pr_merge.REVERT_MARK_RX.search(pr.get("body") or ""):
        return None, ["#%d is itself a revert: never revert a revert" % pr["number"]], info
    reverts = recent_reverts(gh, repo, app)
    mine = [r for r in reverts if r["of"] == pr["number"]]
    if mine:
        merged = [r for r in mine if r["merged_at"]]
        if merged:
            return None, ["#%d was already reverted (#%d) and %s is still red"
                          % (pr["number"], merged[0]["number"], ctx.integration)], info
        r = mine[0]
        if r["state"] != "open":
            return None, ["the revert of #%d (#%d) was closed without merging and %s is still red"
                          % (pr["number"], r["number"], ctx.integration)], info
        info["existing_revert"] = r["number"]
        info["existing_revert_created"] = r["created_at"]
        return info, [], info
    day_ago = mwg.now().timestamp() - 86400
    n24 = sum(1 for r in reverts if (mwg.parse_time(r["created_at"]) or mwg.now()).timestamp() >= day_ago)
    if n24 >= int(ctx.cfg.get("max_reverts_per_day", 1)):
        return None, ["%d automatic revert(s) in the last 24 h (max %d)" % (n24, ctx.cfg.get("max_reverts_per_day", 1))], info
    return info, [], info


def judge_revert(gh, ctx, info, head_sha, v, issue):
    """The App's open revert, judged with merge-when-green's own rules. (wait-note | None,
    reasons-to-escalate)."""
    rev = gh.get("repos/%s/pulls/%d" % (ctx.repo, info["existing_revert"]))
    tag = "revert #%d of #%d" % (info["existing_revert"], info["pr"])
    if rev.get("state") != "open":
        return None, ["%s is %s without merging and %s is still red" % (tag, rev.get("state"), ctx.integration)]
    ctx.develop = {"sha": head_sha, "verdict": "red", "red": v["red"], "missing": v["missing"]}
    ctx.freeze = [issue["number"]] if issue else []
    d = pr_merge.decide_pr(ctx, rev)
    if d["decision"] not in ("merge", "wait"):
        return None, ["%s cannot be merged automatically: %s" % (tag, "; ".join(d["reasons"]))]
    created = mwg.parse_time(rev.get("created_at"))
    age = (mwg.now() - created).total_seconds() / 60 if created else 0
    if age > REVERT_STALE_MINUTES:
        return None, ["%s has been open for %d minutes (> %d): %s" % (tag, age, REVERT_STALE_MINUTES,
                                                                     "; ".join(d["reasons"]))]
    return "%s is open (%s: %s)" % (tag, d["decision"], "; ".join(d["reasons"])), []


def tldr_escalation(repo, integration, head_sha, red, reasons, info, run_url):
    sus = ", ".join(s[:7] for s in (info or {}).get("range", [])) or "sin determinar"
    return (
        "%s\n## TL;DR\n\n"
        "**Qué pasa:** la rama %s de este repositorio está en rojo en el commit %s (%s), y el automático no "
        "puede deshacerlo solo: %s. Mientras esta incidencia tenga la etiqueta merge-freeze no se mergea nada "
        "automáticamente aquí.\n\n"
        "**Commits sospechosos:** %s.\n\n"
        "**Qué se ha hecho y qué no:** se relanzaron una vez los jobs fallidos y siguen en rojo; no se ha "
        "revertido nada.\n\n"
        "**Qué puedes hacer:** arreglar o revertir a mano el commit culpable. Cuando la rama vuelva a verde, "
        "el automático quita la congelación solo; esta incidencia se queda abierta hasta que la cierres tú.\n\n"
        "**Qué NO se ha comprobado:** por qué falla; solo qué commits entraron entre el último verde y el "
        "primer rojo. Ejecución: %s\n"
        % (FREEZE_MARK, integration, head_sha[:7], "; ".join(red[:2]) or "checks obligatorios en rojo",
           "; ".join(reasons), sus, run_url or "(local)"))


def freeze_body(integration, head_sha, red, run_url, note):
    return ("%s\nLa rama %s está en rojo en `%s` (%s). El merge automático queda congelado hasta que vuelva a "
            "verde.\n\n%s\n\nEjecución: %s\n" % (FREEZE_MARK, integration, head_sha[:7], "; ".join(red[:2]),
                                                note, run_url or "(local)"))


def assess(gh, ctx, mode, run_url, write=True):
    repo = ctx.repo
    plan = {"repo": repo, "mode": mode, "action": "none", "notes": [], "revert_pr": "", "revert_sha": ""}
    if not ctx.config_present or ctx.cfg.get("required_push_checks") in (None, []):
        plan["action"] = "skip"
        plan["notes"].append("no usable config: %s" % ("; ".join(ctx.blockers) or "no required_push_checks"))
        return plan
    head = gh.get("repos/%s/commits/%s" % (repo, ctx.integration))
    head_sha = head["sha"]
    plan["head"] = head_sha
    order, by_sha = push_history(gh, repo, ctx.integration)
    runs = by_sha.get(head_sha) or []
    if not runs:
        committed = mwg.parse_time(((head.get("commit") or {}).get("committer") or {}).get("date"))
        if committed and (mwg.now() - committed).total_seconds() > STALL_MINUTES * 60:
            plan["notes"].append("stalled: %s has had no push run for more than %d minutes" % (head_sha[:7], STALL_MINUTES))
        plan["action"] = "wait"
        return plan
    v, bad_jobs, infra, attempts = judge(gh, repo, runs, ctx.cfg["required_push_checks"])
    plan["verdict"] = v["health"]
    plan["red"] = v["red"]
    if v["verdict"] == "red" and v["health"] != "red":
        plan["notes"].append("a job that is not a required push check is red: reported, nothing frozen")
    issue = freeze_issue(gh, repo)
    if v["health"] == "green":
        if issue:
            plan["action"] = "recover"
            if mode == "live":
                gh.write("POST", "repos/%s/issues/%d/comments" % (repo, issue["number"]),
                         {"body": "%s en verde en `%s`: merge automático reanudado." % (ctx.integration, head_sha[:7])})
                gh.write("DELETE", "repos/%s/issues/%d/labels/%s" % (repo, issue["number"], pr_merge.FREEZE_LABEL))
                labels = [lb["name"] for lb in issue.get("labels") or []]
                if pr_merge.ESCALATION_LABEL not in labels:
                    gh.write("PATCH", "repos/%s/issues/%d" % (repo, issue["number"]), {"state": "closed"})
                else:
                    plan["notes"].append("freeze #%d stays open: escalated to the owner" % issue["number"])
                # a revert still open is no longer needed: the branch is green without it
                app = pr_merge.bot_login(ctx.cfg.get("app_slug"))
                for r in (recent_reverts(gh, repo, app) if app else []):
                    if r["state"] == "open" and not r["merged_at"]:
                        gh.write("POST", "repos/%s/issues/%d/comments" % (repo, r["number"]),
                                 {"body": "%s ya está en verde en `%s` sin esta reversión: se cierra sin mergear."
                                          % (ctx.integration, head_sha[:7])})
                        gh.write("PATCH", "repos/%s/pulls/%d" % (repo, r["number"]), {"state": "closed"})
                        plan["notes"].append("closed revert #%d: no longer needed" % r["number"])
        return plan
    if v["health"] != "red":
        plan["action"] = "wait"
        return plan
    if infra:
        plan["action"] = "infra"
        plan["notes"].append("infrastructure red (the job never ran): never reverted")
        rerun = [r for r, j in bad_jobs if j.get("conclusion") in ("startup_failure", "cancelled")
                 and int(r.get("run_attempt") or 1) == 1]
        if rerun and mode == "live":
            gh.write("POST", "repos/%s/actions/runs/%d/rerun" % (repo, rerun[0]["id"]))
            plan["notes"].append("re-ran run %d" % rerun[0]["id"])
        return plan
    if attempts < 2:
        run_ids = sorted({r["id"] for r, _ in bad_jobs})
        plan["notes"].append("re-run of the failed jobs (%s) before blaming anybody" % ", ".join(map(str, run_ids)))
        if mode == "live":
            plan["action"] = "rerun"
            for rid in run_ids:
                gh.write("POST", "repos/%s/actions/runs/%d/rerun-failed-jobs" % (repo, rid))
            return plan
        plan["notes"].append("dry: what follows is what would happen if the re-run stays red")
    info, reasons, culprit = attribute(gh, repo, ctx, order, by_sha, head_sha)
    plan["attribution"] = culprit
    if info and info.get("existing_revert"):
        note, reasons = judge_revert(gh, ctx, info, head_sha, v, issue)
        if note:
            plan["action"] = "wait"
            plan["notes"].append(note)
            return plan
        info = None
    if info:
        plan["action"] = "revert"
        plan["revert_pr"], plan["revert_sha"] = str(info["pr"]), info["first_red"]
    else:
        plan["action"] = "escalate"
        plan["notes"] += reasons
    if mode != "live":
        if culprit.get("pr") and write:
            note = ("SECO: develop-health habría congelado el merge automático y %s."
                    % ("abierto la reversión de esta PR" if plan["action"] == "revert" else
                       "escalado al dueño (%s)" % "; ".join(reasons)))
            upsert_culprit(gh, repo, culprit["pr"], head_sha, note, run_url)
        return plan
    note = ("Se revierte automáticamente #%d (riesgo:%d, mergeada por el automático)." % (info["pr"], info["class"])
            if plan["action"] == "revert" else "Escalado: %s." % "; ".join(reasons))
    if plan["action"] == "escalate":
        body = tldr_escalation(repo, ctx.integration, head_sha, v["red"], reasons, culprit, run_url)
        if issue and pr_merge.ESCALATION_LABEL in [lb["name"] for lb in issue.get("labels") or []]:
            plan["notes"].append("freeze #%d is already with the owner" % issue["number"])
            return plan
        if issue:
            gh.write("PATCH", "repos/%s/issues/%d" % (repo, issue["number"]), {"body": body})
            gh.write("POST", "repos/%s/issues/%d/labels" % (repo, issue["number"]), {"labels": [pr_merge.ESCALATION_LABEL]})
        else:
            pr_merge.open_issue(gh, repo, "%s en rojo: merge automático congelado" % ctx.integration, body,
                                [pr_merge.FREEZE_LABEL, pr_merge.ESCALATION_LABEL])
    elif not issue:
        pr_merge.open_issue(gh, repo, "%s en rojo: merge automático congelado" % ctx.integration,
                            freeze_body(ctx.integration, head_sha, v["red"], run_url, note), [pr_merge.FREEZE_LABEL])
    if culprit.get("pr"):
        upsert_culprit(gh, repo, culprit["pr"], head_sha, note, run_url)
    return plan


def upsert_culprit(gh, repo, pr, head_sha, note, run_url):
    body = "%s head=%s -->\n%s\n\nEjecución: %s" % (CULPRIT_MARK, head_sha[:7], note, run_url or "(local)")
    comments = gh.list("repos/%s/issues/%d/comments" % (repo, pr))
    mine = [c for c in comments if (c.get("user") or {}).get("login") == pr_merge.ACTIONS_BOT
            and (c.get("body") or "").startswith(CULPRIT_MARK)]
    if mine and mine[-1]["body"].split("\n", 1)[0] == body.split("\n", 1)[0]:
        return
    if mine:
        gh.write("PATCH", "repos/%s/issues/comments/%d" % (repo, mine[-1]["id"]), {"body": body})
    else:
        gh.write("POST", "repos/%s/issues/%d/comments" % (repo, pr), {"body": body})


def render(plan):
    out = ["### develop-health · %s · %s" % (plan["repo"], "REAL" if plan["mode"] == "live" else "seco"), "",
           "- cabeza: `%s` · veredicto: %s · acción: **%s**" % ((plan.get("head") or "")[:7], plan.get("verdict", "-"),
                                                                 plan["action"])]
    for r in plan.get("red") or []:
        out.append("- rojo: %s" % r)
    for n in plan["notes"]:
        out.append("- %s" % n)
    if plan.get("attribution"):
        a = plan["attribution"]
        out.append("- atribución: último verde `%s`, primer rojo `%s`, PR #%s" % (
            (a.get("last_green") or "")[:7], (a.get("first_red") or "")[:7], a.get("pr", "-")))
    out.append("- llamadas a la API: %s" % plan.get("api_calls"))
    return "\n".join(out)


def main(argv):
    spec = {"repo": "v", "mode": "v", "plan": "v", "repo_dir": "v", "config": "v", "run_url": "v",
            "selftest_config": "v", "help": "flag"}
    try:
        a, pos = mwg.parse_args(argv, spec)
        if a["help"]:
            print(__doc__)
            return 0
        if pos:
            raise mwg.UsageError("unexpected argument %r" % pos[0])
        repo = mwg.repo_arg(a["repo"])
        if a["mode"] not in ("dry", "live"):
            raise mwg.UsageError("--mode must be dry or live")
        if a["selftest_config"] and a["mode"] != "dry":
            raise mwg.UsageError("--selftest-config is dry and writes nothing: --mode dry")
        gh = mwg.GH(os.environ.get("MWG_READ_TOKEN") or None)
        try:
            gh.check_quota()
        except mwg.QuotaLow as e:
            plan = {"repo": repo, "mode": a["mode"], "action": "wait", "notes": ["API quota: %s" % e],
                    "revert_pr": "", "revert_sha": ""}
        else:
            ctx = pr_merge.Context(gh, repo, a["repo_dir"], a["config"], a["selftest_config"])
            plan = assess(gh, ctx, a["mode"], a["run_url"], write=not a["selftest_config"])
            if a["selftest_config"]:
                plan["notes"].append("self-test: nothing written")
        plan["api_calls"] = gh.calls
        if a["plan"]:
            mwg.write_json(a["plan"], plan)
        mwg.set_output("action", plan["action"])
        mwg.set_output("revert_pr", plan["revert_pr"])
        mwg.set_output("revert_sha", plan["revert_sha"])
        mwg.summary(render(plan))
        print(render(plan))
        return 0
    except mwg.UsageError as e:
        print("develop-health: %s" % e, file=sys.stderr)
        return 2
    except mwg.ApiError as e:
        print("develop-health: could not measure: %s" % e, file=sys.stderr)
        return 2
    except Exception as e:  # fail closed on an unexpected answer
        print("develop-health: could not measure (%s: %s)" % (type(e).__name__, e), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
