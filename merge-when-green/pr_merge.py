#!/usr/bin/env python3
"""pr_merge.py — decide, and in GitHub Actions only, squash-merge a pull request that is safe to
merge without the owner: riesgo-0..`max_auto_class` (never above 2), CI green at job level, the
integration branch green, nothing frozen.

Subcommands:
  decide   --repo R --pr N                    read-only; exit 0 merge · 10 wait · 20 needs a lens
                                              verdict · 30 escalate (never automatic) · 40 skip ·
                                              2 error
  sweep    --repo R --mode dry|live --plan F  decide every open PR into the integration branch (or
           [--pr N | --prs JSON]              only the given ones), label riesgo:N and upsert one
                                              comment per PR with GITHUB_TOKEN, and name AT MOST one
                                              PR to merge (a valid revert first, then the oldest)
  merge    --repo R --pr N --sha S            re-decide with fresh data and PUT the squash merge,
                                              pinned to the evaluated head SHA. Refuses outside
                                              GitHub Actions and with anything but an App
                                              installation token scoped to this one repository
  escalate --repo R --pr N                    label revision-humana with the App token, so the
                                              `labeled` event wakes the TL;DR check (D-21)

Everything a PR author controls is data: titles, bodies, labels and branch names are read from the
API inside this process and travel as JSON, never through a shell or a `${{ }}` expression.
"""
import hashlib
import json
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "risk-class"))
import mwg  # noqa: E402
import ci_verdict  # noqa: E402
import risk_class  # noqa: E402

EXIT = {"merge": 0, "wait": 10, "verdict": 20, "escalate": 30, "skip": 40}
HUMAN_LABELS = ("revision-humana", "sin-revision-independiente", "no-automerge", "merge-freeze")
ESCALATION_LABEL = "revision-humana"
REVERT_LABEL = "revert-on-red"
FREEZE_LABEL = "merge-freeze"
COMMENT_MARK = "<!-- merge-when-green v1"
VERDICT_MARK = "<!-- agent-verdict v1 -->"
ACTIONS_BOT = "github-actions[bot]"
SKIP_CI = re.compile(r"\[(skip ci|ci skip|no ci|skip actions|actions skip)\]", re.I)
SKIP_CHECKS = re.compile(r"^(\s*skip-checks\s*):", re.I | re.M)
TRAILER_RX = re.compile(r"^Risk-class:\s*riesgo:([0-4])\s*$", re.M)
REVERT_MARK_RX = re.compile(r"<!--\s*revert-of:\s*#(\d+)\s+sha:\s*([0-9a-f]{40})\s*-->")


def _sleep(seconds):
    if os.environ.get("MWG_FAKE_SLEEP"):
        os.environ["MWG_NOW"] = mwg.iso(mwg.now() + __import__("datetime").timedelta(seconds=seconds))
        return
    time.sleep(seconds)


def labels_of(pull):
    return [lb["name"] for lb in pull.get("labels") or []]


def bot_login(slug):
    return "%s[bot]" % slug if slug else ""


def neutralize(text):
    """Directives that would stop the push CI on the integration branch must not survive the
    squash: without that run, develop-health is blind to the commit."""
    text = SKIP_CI.sub(lambda m: "(%s)" % m.group(1), text or "")
    return SKIP_CHECKS.sub(lambda m: "%s (neutralized by merge-when-green):" % m.group(1), text)


def compose_message(pull, commits, cls, run_url):
    title = "%s (#%d)" % (pull["title"].strip(), pull["number"])
    parts = []
    msgs = [((c.get("commit") or {}).get("message") or "") for c in commits]
    if len(msgs) == 1:
        body = msgs[0].partition("\n")[2].strip("\n")
        body = re.sub(r"^…[^\n]*(\n+|$)", "", body)
        if body.strip():
            parts.append(body.strip())
    else:
        for m in msgs:
            head, _, body = m.partition("\n")
            block = "* " + head.strip()
            if body.strip():
                block += "\n\n" + "\n".join("  " + ln if ln else "" for ln in body.strip("\n").splitlines())
            parts.append(block)
    trailers = "Risk-class: riesgo:%d\nMerge-gate: merge-when-green %s" % (cls, run_url or "(local)")
    body = "\n\n".join(parts + [trailers])
    return neutralize(title), neutralize(body)


# ── context: everything read once per run ────────────────────────────────────────────────────────
class Context:
    def __init__(self, gh, repo, repo_dir=None, config_path=None, selftest_config=None):
        self.gh, self.repo = gh, repo
        self.meta = gh.get("repos/%s" % repo)
        self.default_branch = self.meta["default_branch"]
        self.private = bool(self.meta.get("private"))
        files = mwg.RepoFiles(gh, repo, self.default_branch, repo_dir)
        self.files = files
        self.blockers = []      # repo-level reasons nothing can merge (config, policy, workflows)
        self.waits = []         # repo-level reasons to wait (develop red, freeze)
        self.policy = mwg.load_policy(files) or {}
        raw = files.read(config_path or mwg.CONFIG_PATH)
        if raw is None and selftest_config:
            with open(selftest_config, encoding="utf-8") as fh:
                raw = fh.read()
            self.selftest = True
        else:
            self.selftest = False
        self.config_present = raw is not None
        cfg = None
        if raw is None:
            self.blockers.append("no %s on %s" % (config_path or mwg.CONFIG_PATH, self.default_branch))
        else:
            cfg, problems = mwg.validate_config(mwg.load_json_text(raw, "config"))
            self.blockers += ["config: %s" % p for p in problems]
        self.cfg = cfg or dict(mwg.CONFIG_DEFAULTS, required_checks=[], required_push_checks=[])
        pol = self.policy
        self.integration = pol.get("integration_branch") or ""
        self.protected = pol.get("protected_branch") or ""
        if pol.get("agent_may_merge") is not True:
            self.blockers.append("guard policy: agent_may_merge is not true")
        if not self.integration:
            self.blockers.append("guard policy: no integration_branch")
        elif self.integration == self.protected:
            self.blockers.append("guard policy: integration_branch equals protected_branch (trunk repo)")
        elif self.integration != self.default_branch:
            self.blockers.append("the integration branch (%s) is not the default branch (%s)"
                                 % (self.integration, self.default_branch))
        # config and policy problems: no PR can get past them, so a sweep does not even evaluate
        self.hard_blockers = list(self.blockers)
        self.long_lived = mwg.long_lived(pol)
        try:
            self.important = mwg.important_pattern(pol)
        except mwg.UsageError as e:
            self.blockers.append(str(e))
            self.important = mwg.DEFAULT_IMPORTANT
        coe = []
        names = files.list_dir(".github/workflows")
        for path in names:
            if not path.endswith((".yml", ".yaml")):
                continue
            text = files.read(path) or ""
            for n, line in enumerate(text.splitlines(), 1):
                m = re.match(r"^\s*continue-on-error:\s*(.*?)\s*(#.*)?$", line)
                if m and m.group(1).strip("'\"") != "false":
                    coe.append("%s:%d" % (path.rsplit("/", 1)[-1], n))
        if coe:
            self.blockers.append("continue-on-error in the integration branch's workflows (%s): a "
                                 "swallowed failure reads as green" % ", ".join(coe[:5]))
        if not any(p.rsplit("/", 1)[-1] in ("develop-health.yml", "develop-health.yaml") for p in names):
            self.blockers.append("no develop-health workflow: without revert-on-red nothing is automatic (D-23)")
        self.develop = None
        self.freeze = []

    def check_integration(self):
        """develop green + no freeze. Costs ~5-8 calls; done once per run."""
        if not self.integration or self.integration == self.protected or \
                self.integration != self.default_branch or not self.cfg.get("required_push_checks"):
            return
        head = self.gh.get("repos/%s/commits/%s" % (self.repo, self.integration))
        self.integration_sha = head["sha"]
        runs = ci_verdict.collect(self.gh, self.repo, head["sha"], "push", self.integration)
        v = ci_verdict.verdict(runs, self.cfg["required_push_checks"], settle=0)
        health = ci_verdict.required_verdict(v)
        self.develop = {"sha": head["sha"], "verdict": health, "red": v["red"], "missing": v["missing"]}
        if health != "green":
            self.waits.append("%s at %s is %s%s" % (self.integration, head["sha"][:7], health,
                                                    (": " + "; ".join(v["red"][:2])) if v["red"] else ""))
        issues = self.gh.list("repos/%s/issues?state=open&labels=%s" % (self.repo, FREEZE_LABEL))
        self.freeze = [i["number"] for i in issues if "pull_request" not in i]
        if self.freeze:
            self.waits.append("merge freeze open (#%s)" % ", #".join(str(n) for n in self.freeze))


# ── one PR ───────────────────────────────────────────────────────────────────────────────────────
def result(pull, decision, reasons, **kw):
    out = {"pr": pull["number"], "sha": pull["head"]["sha"], "title": pull.get("title") or "",
           "created_at": pull.get("created_at") or "", "decision": decision, "reasons": reasons}
    out.update(kw)
    return out


def static_skip(ctx, pull):
    """Reasons that need no extra request. Returns None if the PR goes on."""
    labels = set(labels_of(pull))
    if pull.get("state") != "open":
        return "not open"
    base = pull["base"]["ref"]
    if ctx.protected and base == ctx.protected:
        return "targets %s: a promotion or release is never automatic" % base
    if base != ctx.integration:
        return "targets %s, not the integration branch" % base
    if pull.get("draft"):
        return "draft"
    head_repo = (pull["head"].get("repo") or {}).get("full_name")
    if head_repo != (pull["base"].get("repo") or {}).get("full_name"):
        return "head is in a fork (%s)" % (head_repo or "deleted")
    if pull["head"]["ref"] in ctx.long_lived:
        return "head %s is a long-lived branch" % pull["head"]["ref"]
    held = sorted(labels & set(HUMAN_LABELS))
    if held and not getattr(ctx, "ignore_holds", False):
        return "labelled %s: with a person" % ", ".join(held)
    author = (pull.get("user") or {}).get("login") or ""
    app = bot_login(ctx.cfg.get("app_slug"))
    if app and author == app and REVERT_LABEL not in labels:
        return "opened by the merge App and not a revert"
    if author in (ctx.cfg.get("bot_authors") or []) and risk_class.renovate_automerge(pull.get("body")):
        return "Renovate automerges it itself (Automerge: Enabled)"
    return None


def merge_method_ok(pull, is_bot):
    body = pull.get("body") or ""
    m = re.search(r"^##\s*Merge method\s*$(.*?)(?=^##\s|\Z)", body, re.M | re.S | re.I)
    if not m:
        return is_bot, "no '## Merge method' section" if not is_bot else ""
    sec = m.group(1)
    if re.search(r"^\s*[-*]\s*\[[xX]\]\s*Squash\b", sec, re.M):
        return True, ""
    return False, "the PR template does not tick Squash"


def find_verdict(comments, authors, head_sha):
    """The last agent-verdict v1 by a trusted author, never edited. None if there is none."""
    best = None
    for c in comments:
        if (c.get("user") or {}).get("login") not in authors:
            continue
        body = c.get("body") or ""
        if VERDICT_MARK not in body:
            continue
        if c.get("updated_at") != c.get("created_at"):
            continue
        m = re.search(r"```json\s*(\{.*?\})\s*```", body.split(VERDICT_MARK, 1)[1], re.S)
        if not m:
            continue
        try:
            data = json.loads(m.group(1))
        except ValueError:
            continue
        if best is None or (c.get("created_at") or "") >= (best[0].get("created_at") or ""):
            best = (c, data)
    return best[1] if best else None


def check_verdict(data, head_sha, cls, cfg):
    """(ok, effective-class, reason)."""
    if data is None:
        return False, cls, "riesgo:%d needs a %s verdict pinned to %s" % (cls, risk_class.REVIEW[cls], head_sha[:7])
    if data.get("head_sha") != head_sha:
        return False, cls, "the lens verdict is for %s, the head is %s: ask again" % (str(data.get("head_sha"))[:7], head_sha[:7])
    vcls = data.get("class")
    if not isinstance(vcls, int) or vcls < cls:
        return False, cls, "the verdict's class (%s) is below the computed riesgo:%d" % (vcls, cls)
    if data.get("owner_gate_exit") != 0:
        return False, max(cls, 3), "the owner-decision lens did not clear it (exit %s)" % data.get("owner_gate_exit")
    ps = data.get("pr_score") or {}
    want = cfg.get("pr_score") or {}
    if not (isinstance(ps.get("total"), int) and isinstance(ps.get("axis_min"), int)
            and ps["total"] >= want.get("total", 22) and ps["axis_min"] >= want.get("axis_min", 4)):
        return False, cls, "pr-score below %s/%s" % (want.get("total", 22), want.get("axis_min", 4))
    return True, vcls, ""


def revert_check(ctx, pull):
    """(ok, original-class, reason) for a PR that claims to revert an automatic merge."""
    app = bot_login(ctx.cfg.get("app_slug"))
    if not app or (pull.get("user") or {}).get("login") != app:
        return False, None, "a revert must be opened by the merge App"
    m = REVERT_MARK_RX.search(pull.get("body") or "")
    if not m:
        return False, None, "no revert-of marker"
    orig_n, orig_sha = int(m.group(1)), m.group(2)
    orig = ctx.gh.get("repos/%s/pulls/%d" % (ctx.repo, orig_n))
    if not orig.get("merged_at") or orig.get("merge_commit_sha") != orig_sha:
        return False, None, "#%d is not merged as %s" % (orig_n, orig_sha[:7])
    if (orig.get("merged_by") or {}).get("login") != app:
        return False, None, "#%d was not merged by the App" % orig_n
    commit = ctx.gh.get("repos/%s/commits/%s" % (ctx.repo, orig_sha))
    t = TRAILER_RX.search((commit.get("commit") or {}).get("message") or "")
    if not t:
        return False, None, "the reverted commit has no Risk-class trailer"
    ocls = int(t.group(1))
    if ocls > 2:
        return False, ocls, "the reverted commit is riesgo:%d" % ocls
    mine = sorted(f["filename"] for f in ctx.gh.list("repos/%s/pulls/%d/files" % (ctx.repo, pull["number"])))
    theirs = sorted(f["filename"] for f in ctx.gh.list("repos/%s/pulls/%d/files" % (ctx.repo, orig_n)))
    if mine != theirs:
        return False, ocls, "the revert does not touch exactly the files of #%d" % orig_n
    return True, ocls, "reverts #%d (riesgo:%d)" % (orig_n, ocls)


def decide_pr(ctx, pull, open_pulls=()):
    gh, cfg = ctx.gh, ctx.cfg
    if ctx.hard_blockers:
        return result(pull, "skip", ["repo not eligible: %s" % b for b in ctx.hard_blockers], static=True)
    skip = static_skip(ctx, pull)
    if skip:
        return result(pull, "skip", [skip], static=True)
    labels = labels_of(pull)
    head_sha = pull["head"]["sha"]
    required = cfg.get("required_checks") or []

    # A revert of an automatic merge: own path, exempt from the freeze, a red develop, the class
    # ceiling, the lens verdict, semver and the method — those are what it exists to undo.
    if REVERT_LABEL in labels:
        ok, ocls, why = revert_check(ctx, pull)
        if not ok:
            return result(pull, "skip", ["invalid revert: %s" % why], revert=True)
        if ctx.blockers:
            return result(pull, "skip", ["repo not eligible: %s" % b for b in ctx.blockers], revert=True)
        v = ci_verdict.evaluate(gh, ctx.repo, head_sha, "pull_request", required,
                                state_workflows=cfg["state_workflows"], settle=cfg["settle_seconds"])
        ci = {k: v[k] for k in ("verdict", "red", "pending", "missing", "required_green", "required_total", "settle_left")}
        if v["verdict"] == "green":
            return result(pull, "merge", [why], revert=True, cls=ocls, ci=ci)
        if v["verdict"] == "red":
            return result(pull, "skip", ["the revert's CI is red: develop-health escalates"], revert=True, cls=ocls, ci=ci)
        return result(pull, "wait", ["CI %s" % v["verdict"]], revert=True, cls=ocls, ci=ci)

    facts, _ = risk_class.collect_api(gh, ctx.repo, pull["number"], ctx.policy, cfg, pull=pull)
    rc = risk_class.classify(facts, ctx.policy, cfg)
    cls = rc["class"]
    is_bot = rc["bot"]
    base_kw = {"risk": {k: rc[k] for k in ("class", "label", "review", "reasons", "files", "lines_code", "bot")}}
    max_auto = int(cfg.get("max_auto_class", 0))

    if cls <= 2 and cls > max_auto:
        return result(pull, "skip", ["riesgo:%d is above max_auto_class=%d: stays in the session/owner flow"
                                     % (cls, max_auto)], cls=cls, **base_kw)

    v = ci_verdict.evaluate(gh, ctx.repo, head_sha, "pull_request", required,
                            state_workflows=cfg["state_workflows"], settle=cfg["settle_seconds"],
                            important_pattern=ctx.important, head_branch=pull["head"]["ref"],
                            pr=pull["number"], since=pull.get("created_at"))
    ci = {k: v[k] for k in ("verdict", "red", "pending", "missing", "required_green", "required_total", "settle_left")}
    ci["important"] = v["important"]
    base_kw["ci"] = ci
    if v["important"]:
        facts["min_class"] = 3
        facts["min_reason"] = "an important check failed in this PR's life (%s)" % v["important"][0]["job"]
        rc = risk_class.classify(facts, ctx.policy, cfg)
        cls = rc["class"]
        base_kw["risk"] = {k: rc[k] for k in ("class", "label", "review", "reasons", "files", "lines_code", "bot")}

    def escalate_or_wait(c, why):
        if is_bot:
            return result(pull, "skip", ["riesgo:%d on a bot PR: it stays in the dependency flow, never "
                                         "labelled for the owner" % c, why], cls=c, **base_kw)
        if v["verdict"] == "green":
            return result(pull, "escalate", ["riesgo:%d: %s" % (c, why)], cls=c, **base_kw)
        if v["verdict"] == "red":
            return result(pull, "skip", ["riesgo:%d and CI red: the author fixes it before the owner sees it" % c],
                          cls=c, **base_kw)
        return result(pull, "wait", ["riesgo:%d: escalates once CI is green (now %s)" % (c, v["verdict"])],
                      cls=c, **base_kw)

    if cls >= 3:
        top = rc["reasons"][0]
        return escalate_or_wait(cls, "%s (%s)" % (top["why"], ", ".join(top["paths"][:3]) or top["rule"]))

    reasons = []
    if rc["missing_semver"]:
        reasons.append("not exactly one semver:* label (%s)" % (", ".join(rc["semver"]) or "none"))
    if rc["touches_workflows"]:
        reasons.append("touches .github/workflows: the App has no workflows permission")
    kids = [p["number"] for p in open_pulls if p["base"]["ref"] == pull["head"]["ref"] and not p.get("draft")]
    if kids:
        reasons.append("stacked PRs on top of it (#%s)" % ", #".join(map(str, kids)))
    ok, why = merge_method_ok(pull, is_bot)
    if not ok:
        reasons.append(why)
    if reasons:
        return result(pull, "skip", reasons, cls=cls, **base_kw)

    if cls >= 1:
        comments = gh.list("repos/%s/issues/%d/comments" % (ctx.repo, pull["number"]))
        data = find_verdict(comments, cfg.get("verdict_authors") or [], head_sha)
        ok, vcls, why = check_verdict(data, head_sha, cls, cfg)
        if vcls >= 3:
            return escalate_or_wait(vcls, why or "the lens raised it")
        if not ok:
            return result(pull, "verdict", [why], cls=cls, **base_kw)
        if vcls > max_auto:
            return result(pull, "skip", ["the lens raised it to riesgo:%d, above max_auto_class=%d"
                                         % (vcls, max_auto)], cls=vcls, **base_kw)
        cls = vcls

    if v["verdict"] == "red":
        return result(pull, "skip", ["CI red: %s" % "; ".join(v["red"][:3])], cls=cls, **base_kw)
    if v["verdict"] != "green":
        detail = {"pending": "; ".join(v["pending"][:3]), "missing": "; ".join(v["missing"][:3]),
                  "unsettled": "settling, %ds left" % v["settle_left"]}.get(v["verdict"], "")
        return result(pull, "wait", ["CI %s: %s" % (v["verdict"], detail)], cls=cls, **base_kw)

    fresh = gh.get("repos/%s/pulls/%d" % (ctx.repo, pull["number"]))
    if fresh["head"]["sha"] != head_sha:
        return result(pull, "wait", ["the head moved while deciding"], cls=cls, **base_kw)
    if fresh.get("mergeable") is None:
        return result(pull, "wait", ["GitHub is still computing mergeability"], cls=cls, **base_kw)
    if fresh.get("mergeable") is False or fresh.get("mergeable_state") == "dirty":
        return result(pull, "skip", ["merge conflicts"], cls=cls, **base_kw)
    return result(pull, "merge", ["riesgo:%d, CI green (%d/%d required)" % (cls, v["required_green"], v["required_total"])],
                  cls=cls, **base_kw)


def apply_repo_gates(ctx, d):
    """A PR that would merge waits while the repo is not eligible or develop is not green."""
    if d["decision"] != "merge":
        return d
    if ctx.blockers:
        d["decision"] = "skip"
        d["reasons"] = ["repo not eligible: %s" % b for b in ctx.blockers] + d["reasons"]
    elif ctx.waits and not d.get("revert"):
        d["decision"] = "wait"
        d["reasons"] = ctx.waits + d["reasons"]
    return d


# ── comments and labels (GITHUB_TOKEN: no workflow is triggered by them) ──────────────────────────
DECISION_ES = {"merge": "se mergearía", "wait": "espera", "verdict": "falta el veredicto de la lente",
               "escalate": "no es automática: va al dueño", "skip": "no la mergea el automático"}


def render_comment(d, mode, ctx, run_url, merged=False):
    cls = d.get("cls")
    marker_core = "head=%s decision=%s class=%s why=%s" % (
        d["sha"][:7], "merged" if merged else d["decision"], cls,
        hashlib.sha256(json.dumps(d["reasons"], sort_keys=True).encode()).hexdigest()[:10])
    lines = ["%s %s -->" % (COMMENT_MARK, marker_core),
             "**merge-when-green** (%s) · `%s`" % ("REAL" if mode == "live" else "SECO: no mergea nada", d["sha"][:7]),
             ""]
    if merged:
        lines.append("**Decisión:** mergeada por el automático.")
    else:
        lines.append("**Decisión:** %s." % DECISION_ES[d["decision"]])
    for r in d["reasons"]:
        lines.append("- %s" % r)
    risk = d.get("risk")
    if risk:
        lines += ["", "**Clase:** `riesgo:%d` (revisión: %s)" % (risk["class"], risk["review"])]
        for r in risk["reasons"][:6]:
            lines.append("- %d · %s%s" % (r["class"], r["why"], (": " + ", ".join("`%s`" % p for p in r["paths"][:4])) if r["paths"] else ""))
    ci = d.get("ci")
    if ci:
        lines += ["", "**CI:** %s · obligatorias %d/%d en verde" % (ci["verdict"], ci["required_green"], ci["required_total"])]
        for k in ("red", "pending", "missing"):
            for x in ci.get(k) or []:
                lines.append("- %s: %s" % (k, x))
        for x in ci.get("important") or []:
            lines.append("- check importante fallido: %s / %s (run %s)" % (x["workflow"], x["job"], x["run_id"]))
    if ctx.develop:
        lines.append("**%s:** `%s` %s" % (ctx.integration, ctx.develop["sha"][:7], ctx.develop["verdict"]))
    if d.get("message") and mode != "live":
        lines += ["", "<details><summary>Mensaje que usaría</summary>", "", "```", d["message"]["title"], "",
                  d["message"]["body"][:1500], "```", "</details>"]
    if run_url:
        lines += ["", "[run](%s)" % run_url]
    return "\n".join(lines), marker_core


def upsert_comment(gh, repo, d, mode, ctx, run_url, merged=False):
    body, core = render_comment(d, mode, ctx, run_url, merged)
    comments = gh.list("repos/%s/issues/%d/comments" % (repo, d["pr"]))
    mine = [c for c in comments if (c.get("user") or {}).get("login") == ACTIONS_BOT
            and (c.get("body") or "").startswith(COMMENT_MARK)]
    if mine:
        c = mine[-1]
        if (c.get("body") or "").split("\n", 1)[0] == body.split("\n", 1)[0]:
            return "unchanged"
        st, _ = gh.write("PATCH", "repos/%s/issues/comments/%d" % (repo, c["id"]), {"body": body})
        return "updated" if st < 300 else "error %s" % st
    st, _ = gh.write("POST", "repos/%s/issues/%d/comments" % (repo, d["pr"]), {"body": body})
    return "created" if st < 300 else "error %s" % st


def sync_risk_label(gh, repo, pull, cls):
    want = "riesgo:%d" % cls
    have = [x for x in labels_of(pull) if x.startswith("riesgo:")]
    done = []
    for x in have:
        if x != want:
            gh.write("DELETE", "repos/%s/issues/%d/labels/%s" % (repo, pull["number"], x.replace(":", "%3A")))
            done.append("-" + x)
    if want not in have:
        st, _ = gh.write("POST", "repos/%s/issues/%d/labels" % (repo, pull["number"]), {"labels": [want]})
        done.append("+%s%s" % (want, "" if st < 300 else " (error %s)" % st))
    return done


# ── subcommands ──────────────────────────────────────────────────────────────────────────────────
def read_gh():
    return mwg.GH(os.environ.get("MWG_READ_TOKEN") or None, "read")


def candidates(ctx, only=None):
    pulls = ctx.gh.list("repos/%s/pulls?state=open&base=%s&sort=created&direction=asc" % (ctx.repo, ctx.integration)) \
        if ctx.integration else []
    if only is not None:
        have = {p["number"]: p for p in pulls}
        out = []
        for n in only:
            out.append(have.get(n) or ctx.gh.get("repos/%s/pulls/%d" % (ctx.repo, n)))
        return out, pulls
    return pulls, pulls


def cmd_decide(a):
    repo, pr = mwg.repo_arg(a["repo"]), mwg.pr_arg(a["pr"])
    gh = read_gh()
    ctx = Context(gh, repo, a["repo_dir"], a["config"])
    ctx.check_integration()
    pull = gh.get("repos/%s/pulls/%d" % (repo, pr))
    open_pulls = gh.list("repos/%s/pulls?state=open" % repo)
    d = apply_repo_gates(ctx, decide_pr(ctx, pull, open_pulls))
    d["api_calls"] = gh.calls
    if a["json"]:
        print(json.dumps(d, sort_keys=True))
    else:
        print("#%d %s: %s" % (d["pr"], d["decision"].upper(), "; ".join(d["reasons"])))
    return EXIT[d["decision"]]


def cmd_sweep(a):
    repo = mwg.repo_arg(a["repo"])
    mode = a["mode"]
    if mode not in ("dry", "live"):
        raise mwg.UsageError("--mode must be dry or live")
    plan_path = a["plan"] or ""
    comment = (a["comment"] or "true") == "true"
    label = (a["labels"] or "true") == "true"
    only = None
    if a["pr"]:
        only = [mwg.pr_arg(a["pr"])]
    elif a["prs"] is not None:
        try:
            raw = json.loads(a["prs"] or "[]")
        except ValueError:
            raise mwg.UsageError("--prs must be a JSON list of numbers")
        only = [mwg.pr_arg(x) for x in raw]
    gh = read_gh()
    plan = {"repo": repo, "mode": mode, "decisions": [], "merge_pr": "", "merge_sha": "", "escalate": [],
            "preconditions": [], "waits": []}

    def finish(code=0):
        plan["api_calls"] = gh.calls
        if plan_path:
            mwg.write_json(plan_path, plan)
        mwg.set_output("merge_pr", plan["merge_pr"])
        mwg.set_output("merge_sha", plan["merge_sha"])
        mwg.set_output("escalate_prs", json.dumps(plan["escalate"]))
        mwg.set_output("decision", json.dumps({"merge": plan["merge_pr"], "escalate": plan["escalate"],
                                               "decisions": {str(d["pr"]): d["decision"] for d in plan["decisions"]},
                                               "blocked": plan["preconditions"][:3], "waits": plan["waits"][:3]}))
        mwg.summary(render_plan(plan))
        print(render_plan(plan))
        return code

    try:
        gh.check_quota()
    except mwg.QuotaLow as e:
        plan["waits"].append("API quota: %s" % e)
        return finish()
    if only == []:
        plan["waits"].append("the triggering run carries no pull request: nothing to evaluate")
        return finish()
    ctx = Context(gh, repo, a["repo_dir"], a["config"], a["selftest_config"])
    if a["selftest_config"]:
        # The self-test of this repo's CI: dry and without writes no matter what was asked, and it
        # looks past the hold labels so the whole decision path runs against a real PR in GitHub.
        if mode != "dry" or comment or label:
            raise mwg.UsageError("--selftest-config is dry and read-only: --mode dry --comment false --labels false")
        ctx.ignore_holds = True
        plan["note"] = "self-test: hold labels ignored, nothing written"
    plan["integration"] = ctx.integration
    plan["preconditions"] = list(ctx.blockers)
    if ctx.hard_blockers:
        plan["waits"].append("nothing evaluated: the config or the guard policy rules automatic merging out")
        return finish()
    ctx.check_integration()
    plan["waits"] = list(ctx.waits)
    plan["develop"] = ctx.develop
    pulls, open_pulls = candidates(ctx, only)
    # reverts first, then oldest first; static skips cost nothing and are not counted
    pulls = sorted(pulls, key=lambda p: (REVERT_LABEL not in labels_of(p), p.get("created_at") or ""))
    budget = int(a["max_candidates"] or ctx.cfg.get("max_candidates", 5))
    evaluated = 0
    max_wait = int(a["max_settle_wait"] or 0)
    for pull in pulls:
        if static_skip(ctx, pull) is None:
            if evaluated >= budget:
                plan["decisions"].append(result(pull, "wait", ["over max_candidates=%d this run" % budget]))
                continue
            evaluated += 1
        try:
            gh.check_quota() if gh.calls and gh.calls % 40 == 0 else None
            d = decide_pr(ctx, pull, open_pulls)
            if d["decision"] == "wait" and (d.get("ci") or {}).get("verdict") == "unsettled" and \
                    0 < d["ci"]["settle_left"] <= max_wait and not plan["merge_pr"]:
                _sleep(d["ci"]["settle_left"] + 5)
                d = decide_pr(ctx, gh.get("repos/%s/pulls/%d" % (repo, pull["number"])), open_pulls)
        except mwg.QuotaLow as e:
            plan["waits"].append("API quota: %s" % e)
            break
        except (mwg.ApiError, mwg.UsageError) as e:
            d = result(pull, "skip", ["could not measure: %s" % e])
        except Exception as e:  # malformed API data: this PR is unmeasured, the others still count
            d = result(pull, "skip", ["could not measure (%s: %s)" % (type(e).__name__, e)])
        d = apply_repo_gates(ctx, d)
        if d["decision"] == "merge":
            if plan["merge_pr"]:
                d["decision"], d["reasons"] = "wait", ["one merge per run: #%s goes first" % plan["merge_pr"]] + d["reasons"]
            else:
                commits = gh.list("repos/%s/pulls/%d/commits" % (repo, pull["number"]))
                t, b = compose_message(pull, commits, d.get("cls") or 0, a["run_url"])
                d["message"] = {"title": t, "body": b}
                plan["merge_pr"], plan["merge_sha"] = str(pull["number"]), pull["head"]["sha"]
        if d["decision"] == "escalate":
            plan["escalate"].append(pull["number"])
        if not d.get("static"):
            if label and d.get("cls") is not None and not d.get("revert"):
                d["labels_changed"] = sync_risk_label(gh, repo, pull, d["cls"])
            if comment:
                d["comment"] = upsert_comment(gh, repo, d, mode, ctx, a["run_url"])
        plan["decisions"].append(d)
    if mode != "live":
        plan["note"] = "dry run: nothing merged, nothing escalated"
    return finish()


def require_app_token(repo):
    if os.environ.get("GITHUB_ACTIONS") != "true":
        raise mwg.UsageError("merge runs only inside GitHub Actions (the session has `decide`)")
    if os.environ.get("MWG_WRITE_TOKEN_KIND") != "app":
        raise mwg.UsageError("merge needs MWG_WRITE_TOKEN_KIND=app")
    tok = os.environ.get("MWG_WRITE_TOKEN") or ""
    if not tok.startswith("ghs_") or tok == (os.environ.get("MWG_READ_TOKEN") or ""):
        raise mwg.UsageError("the write token is not a GitHub App installation token distinct from GITHUB_TOKEN")
    wgh = mwg.GH(tok, "write")
    data = wgh.get("installation/repositories")
    names = [r.get("full_name") for r in (data or {}).get("repositories") or []]
    if (data or {}).get("total_count") != 1 or names != [repo]:
        raise mwg.UsageError("the App token reaches %s repositories (%s), not exactly %s"
                             % ((data or {}).get("total_count"), ", ".join(names[:3]), repo))
    return wgh


def cmd_merge(a):
    repo, pr, sha = mwg.repo_arg(a["repo"]), mwg.pr_arg(a["pr"]), mwg.sha_arg(a["sha"])
    wgh = require_app_token(repo)
    gh = read_gh()
    ctx = Context(gh, repo, a["repo_dir"], a["config"])
    slug = os.environ.get("MWG_APP_SLUG") or ""
    if not slug or slug != ctx.cfg.get("app_slug"):
        raise mwg.UsageError("the token belongs to App %r, the config trusts %r: develop-health could not revert "
                             "this merge" % (slug, ctx.cfg.get("app_slug")))
    ctx.check_integration()
    d = None
    for attempt in range(6):
        pull = gh.get("repos/%s/pulls/%d" % (repo, pr))
        if pull.get("merged_at"):
            print("#%d already merged: nothing to do" % pr)
            return 0
        if pull["head"]["sha"] != sha:
            print("#%d head moved (%s != %s): wait" % (pr, pull["head"]["sha"][:7], sha[:7]))
            return 10
        open_pulls = gh.list("repos/%s/pulls?state=open" % repo)
        d = apply_repo_gates(ctx, decide_pr(ctx, pull, open_pulls))
        if d["decision"] == "wait" and d["reasons"] == ["GitHub is still computing mergeability"] and attempt < 5:
            _sleep(10)
            continue
        break
    if d["decision"] != "merge":
        print("#%d re-decided %s: %s" % (pr, d["decision"], "; ".join(d["reasons"])))
        return EXIT[d["decision"]]
    commits = gh.list("repos/%s/pulls/%d/commits" % (repo, pr))
    title, body = compose_message(pull, commits, d.get("cls") or 0, a["run_url"])
    st, resp = wgh.write("PUT", "repos/%s/pulls/%d/merge" % (repo, pr),
                         {"merge_method": "squash", "sha": sha, "commit_title": title, "commit_message": body})
    if st in (405, 409, 422):
        print("#%d not merged (HTTP %s: %s): wait" % (pr, st, (resp or {}).get("message", "")))
        return 10
    if st != 200:
        print("#%d merge failed (HTTP %s: %s)" % (pr, st, (resp or {}).get("message", "")), file=sys.stderr)
        return 1
    print("#%d MERGED as %s" % (pr, (resp or {}).get("sha", "?")))
    problems = post_merge_check(gh, ctx, pr)
    if problems:
        open_issue(gh, repo, "merge-when-green: comprobar el merge de #%d" % pr,
                   tldr_post_merge(repo, pr, problems, a["run_url"]), [ESCALATION_LABEL])
        print("post-merge check failed: %s" % "; ".join(problems), file=sys.stderr)
        return 1
    if (a["comment"] or "true") == "true":
        upsert_comment(gh, repo, d, "live", ctx, a["run_url"], merged=True)
    return 0


def post_merge_check(gh, ctx, pr):
    problems = []
    pull = gh.get("repos/%s/pulls/%d" % (ctx.repo, pr))
    if pull["base"]["ref"] != ctx.integration:
        problems.append("merged into %s, not %s" % (pull["base"]["ref"], ctx.integration))
    held = sorted(set(labels_of(pull)) & set(HUMAN_LABELS))
    if held:
        problems.append("it carries %s" % ", ".join(held))
    for b in (ctx.integration, ctx.protected):
        if b and gh.get_or_none("repos/%s/branches/%s" % (ctx.repo, b)) is None:
            problems.append("branch %s no longer exists" % b)
    return problems


def tldr_post_merge(repo, pr, problems, run_url):
    return ("## TL;DR\n\n**Qué ha pasado:** el merge automático de la PR %d de este repositorio salió, pero la "
            "comprobación de después no cuadra: %s. Puede ser una carrera (alguien cambió la PR en el segundo "
            "del merge) o algo peor; por eso no se ha seguido mergeando nada más hasta que lo mires.\n\n"
            "**Qué puede salir mal y cómo se deshace:** si el cambio no debía entrar, se revierte el commit "
            "del merge con una PR de reversión normal.\n\n**Qué NO se ha comprobado:** si el cambio en sí es "
            "correcto; solo que la comprobación posterior falló. Ejecución: %s\n"
            % (pr, "; ".join(problems), run_url or "(local)"))


def open_issue(gh, repo, title, body, labels):
    st, data = gh.write("POST", "repos/%s/issues" % repo, {"title": title, "body": body, "labels": labels})
    return (data or {}).get("number") if st < 300 else None


def cmd_escalate(a):
    repo, pr = mwg.repo_arg(a["repo"]), mwg.pr_arg(a["pr"])
    wgh = require_app_token(repo)
    gh = read_gh()
    pull = gh.get("repos/%s/pulls/%d" % (repo, pr))
    if pull.get("state") != "open" or ESCALATION_LABEL in labels_of(pull):
        print("#%d: nothing to escalate" % pr)
        return 0
    st, _ = wgh.write("POST", "repos/%s/issues/%d/labels" % (repo, pr), {"labels": [ESCALATION_LABEL]})
    if st >= 300:
        print("#%d: could not label (HTTP %s)" % (pr, st), file=sys.stderr)
        return 1
    print("#%d escalated: %s" % (pr, ESCALATION_LABEL))
    return 0


def render_plan(plan):
    out = ["### merge-when-green · %s · %s" % (plan["repo"], "REAL" if plan["mode"] == "live" else "seco"), ""]
    for p in plan.get("preconditions") or []:
        out.append("- bloqueo del repo: %s" % p)
    for w in plan.get("waits") or []:
        out.append("- espera: %s" % w)
    out.append("")
    out.append("| PR | decisión | clase | CI | motivo |")
    out.append("|---|---|---|---|---|")
    for d in plan["decisions"]:
        out.append("| #%s | %s | %s | %s | %s |" % (d["pr"], d["decision"], "-" if d.get("cls") is None else d["cls"],
                                                 (d.get("ci") or {}).get("verdict", "-"),
                                                 "; ".join(d["reasons"])[:200].replace("|", "/")))
    out.append("")
    out.append("merge: %s · escalate: %s · llamadas a la API: %s" % (plan["merge_pr"] or "ninguna",
                                                                 plan["escalate"] or "ninguna", plan.get("api_calls")))
    return "\n".join(out)


SPEC = {"repo": "v", "pr": "v", "prs": "v", "sha": "v", "mode": "v", "plan": "v", "comment": "v",
        "labels": "v", "repo_dir": "v", "config": "v", "run_url": "v", "json": "flag", "max_candidates": "v",
        "max_settle_wait": "v", "selftest_config": "v", "help": "flag"}


def main(argv):
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(__doc__)
        return 0 if argv else 2
    sub, rest = argv[0], argv[1:]
    try:
        a, pos = mwg.parse_args(rest, SPEC)
        if pos:
            raise mwg.UsageError("unexpected argument %r" % pos[0])
        if sub == "decide":
            return cmd_decide(a)
        if sub == "sweep":
            return cmd_sweep(a)
        if sub == "merge":
            return cmd_merge(a)
        if sub == "escalate":
            return cmd_escalate(a)
        raise mwg.UsageError("unknown subcommand %r (decide, sweep, merge, escalate)" % sub)
    except mwg.UsageError as e:
        print("pr-merge: %s" % e, file=sys.stderr)
        return 2
    except mwg.QuotaLow as e:
        print("pr-merge: API quota low: %s" % e, file=sys.stderr)
        return 10
    except mwg.ApiError as e:
        print("pr-merge: could not measure: %s" % e, file=sys.stderr)
        return 2
    except Exception as e:  # fail closed: an unexpected answer is never a merge
        print("pr-merge: could not measure (%s: %s)" % (type(e).__name__, e), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
