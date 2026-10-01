#!/usr/bin/env python3
"""ci_verdict.py — is CI green on this commit, at JOB level, keyed by workflow file and job name?

It replaces the "checks by name" readings that let a red through:

  * the key is `<workflow file> + <job name>`, never the job name alone: two workflows of a
    consuming repo both have a job called `build`, and a success in one hid a failure in the other;
  * jobs are read for EVERY run of the commit (all attempts), never inferred from the run's
    conclusion: a run can be `success` with the required job `skipped` by an `if:`;
  * a required job that only ever `skipped` (or only `neutral`) is MISSING, not green;
  * only `success` is green (and `neutral` for jobs nobody requires): every other conclusion,
    including ones GitHub adds later, is red;
  * a failure is cleared only by a later attempt of the SAME run (a re-run). A success in a
    different run of the same workflow does not hide it, because two runs of one commit are a
    flaky test or two concurrent events, and created_at is not event order. Exceptions: a
    `cancelled` run superseded by a later good run (concurrency did that), and the workflows a repo
    lists in `state_workflows` — checks that re-read live PR state (labels, title, body) on every
    event, where the latest run IS the truth;
  * a failed STEP inside a successful job (continue-on-error) is red;
  * other Apps' check runs and commit statuses count (failure/error red, pending pending);
  * green also needs `settle` seconds since the last completion: workflows register late.

`important` (with --head-branch): every run of the PR's branch since the PR was opened, every
attempt, looking for a failed job whose job, workflow or failed-step name matches the important
pattern (security and the guard). A red there that a re-run turned green still goes to the owner.

    ci-verdict.sh --repo R --sha S --event pull_request|push [--branch B] --required JSON
                  [--state-workflows JSON] [--important ERE --head-branch H --pr N --since ISO]
                  [--settle 120] [--json]

Exit 0 measured (the verdict is in the output) · 2 could not measure.
"""
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mwg  # noqa: E402

GOOD = ("success",)
GOOD_OPTIONAL = ("success", "neutral")


def _wf(path):
    return (path or "").split("@", 1)[0].rsplit("/", 1)[-1]


def _job_state(job):
    """(state, detail) for one job entry: pending | good | neutral | skipped | bad."""
    if job.get("status") != "completed":
        return "pending", job.get("status") or "queued"
    c = job.get("conclusion") or "unknown"
    if c == "success":
        failed = [s.get("name") for s in job.get("steps") or [] if s.get("conclusion") == "failure"]
        if failed:
            return "bad", "step failed inside a successful job (continue-on-error): %s" % ", ".join(failed[:3])
        return "good", c
    if c == "neutral":
        return "neutral", c
    if c == "skipped":
        return "skipped", c
    return "bad", c


def infra_failure(job):
    """A red the code did not cause: the job never really ran."""
    c = job.get("conclusion")
    if c in ("cancelled", "startup_failure"):
        return True
    if c in ("failure", "timed_out") and (not job.get("steps") or not job.get("runner_name")):
        return True
    return False


def collect(gh, repo, sha, event, branch=None):
    """Runs of the commit for one event, with every job of every attempt."""
    runs = gh.list("repos/%s/actions/runs?head_sha=%s" % (repo, sha), key="workflow_runs")
    runs = [r for r in runs if r.get("event") == event and (branch is None or r.get("head_branch") == branch)]
    for r in runs:
        r["_jobs"] = gh.list("repos/%s/actions/runs/%d/jobs?filter=all" % (repo, r["id"]), key="jobs")
    return runs


def collect_external(gh, repo, sha):
    checks = gh.list("repos/%s/commits/%s/check-runs?filter=all" % (repo, sha), key="check_runs")
    checks = [c for c in checks if ((c.get("app") or {}).get("slug") or "") != "github-actions"]
    status = gh.get("repos/%s/commits/%s/status" % (repo, sha)) or {}
    return checks, status.get("statuses") or []


def verdict(runs, required, checks=(), statuses=(), state_workflows=(), settle=120, now=None):
    now = now or mwg.now()
    required_keys = [(e["workflow"], e["job"]) for e in required]
    state_wf = set(state_workflows or ())
    entries = {}
    last_completed = None
    for r in runs:
        wf = _wf(r.get("path"))
        for j in r.get("_jobs") or []:
            key = (wf, j.get("name") or "")
            entries.setdefault(key, []).append({
                "run_id": r["id"], "attempt": int(j.get("run_attempt") or r.get("run_attempt") or 1),
                "created": r.get("created_at") or "", "started": j.get("started_at") or "",
                "job": j,
            })
            t = mwg.parse_time(j.get("completed_at"))
            if t and (last_completed is None or t > last_completed):
                last_completed = t
    keys = []
    for key, ents in sorted(entries.items()):
        # the latest attempt of each run decides that run
        per_run = {}
        for e in ents:
            cur = per_run.get(e["run_id"])
            if cur is None or (e["attempt"], e["started"]) > (cur["attempt"], cur["started"]):
                per_run[e["run_id"]] = e
        ordered = sorted(per_run.values(), key=lambda e: (e["created"], e["run_id"]))
        states = [(e,) + _job_state(e["job"]) for e in ordered]
        is_required = key in required_keys
        latest_wins = key[0] in state_wf
        state, detail = "green", ""
        if any(s == "pending" for _, s, _ in states):
            state, detail = "pending", next(d for _, s, d in states if s == "pending")
        else:
            if latest_wins:
                considered = [x for x in states if x[1] != "skipped"][-1:]
            else:
                considered = []
                for i, x in enumerate(states):
                    e, s, d = x
                    if s == "bad" and e["job"].get("conclusion") == "cancelled" and \
                            any(y[1] in ("good", "neutral") for y in states[i + 1:]):
                        continue  # superseded by concurrency
                    if s != "skipped":
                        considered.append(x)
            bad = [x for x in considered if x[1] == "bad"]
            good_states = ("good",) if is_required else ("good", "neutral")
            if bad:
                state, detail = "red", "; ".join(sorted(set(d for _, _, d in bad)))
            elif not any(x[1] in good_states for x in considered):
                state = "missing" if is_required else "ignored"
                detail = "only %s" % (",".join(sorted(set(s for _, s, _ in states))) or "no entries")
        keys.append({"workflow": key[0], "job": key[1], "required": is_required, "state": state,
                     "detail": detail, "runs": len(per_run)})
    for wf, job in required_keys:
        if (wf, job) not in entries:
            keys.append({"workflow": wf, "job": job, "required": True, "state": "missing",
                         "detail": "no job with this name in this workflow", "runs": 0})

    external = []
    latest = {}
    for c in checks:
        k = ((c.get("app") or {}).get("slug") or "?", c.get("name") or "")
        if k not in latest or (c.get("id") or 0) > (latest[k].get("id") or 0):
            latest[k] = c
    for (app, name), c in sorted(latest.items()):
        if c.get("status") != "completed":
            st = "pending"
        elif c.get("conclusion") in ("success", "neutral", "skipped"):
            st = "green"
        else:
            st = "red"
        t = mwg.parse_time(c.get("completed_at"))
        if t and (last_completed is None or t > last_completed):
            last_completed = t
        external.append({"app": app, "name": name, "state": st, "detail": c.get("conclusion") or c.get("status")})
    for s in statuses:
        st = {"success": "green", "pending": "pending"}.get(s.get("state"), "red")
        external.append({"app": "status", "name": s.get("context"), "state": st, "detail": s.get("state")})

    red = [k for k in keys if k["state"] == "red"] + [x for x in external if x["state"] == "red"]
    pending = [k for k in keys if k["state"] == "pending"] + [x for x in external if x["state"] == "pending"]
    missing = [k for k in keys if k["state"] == "missing"]
    age = (now - last_completed).total_seconds() if last_completed else None
    if red:
        overall = "red"
    elif pending:
        overall = "pending"
    elif missing:
        overall = "missing"
    elif age is None or age < settle:
        overall = "unsettled"
    else:
        overall = "green"
    return {
        "verdict": overall,
        "keys": keys,
        "external": external,
        "red": ["%s / %s: %s" % (k.get("workflow", k.get("app")), k.get("job", k.get("name")), k["detail"]) for k in red],
        "pending": ["%s / %s" % (k.get("workflow", k.get("app")), k.get("job", k.get("name"))) for k in pending],
        "missing": ["%s / %s" % (k["workflow"], k["job"]) for k in missing],
        "required_green": sum(1 for k in keys if k["required"] and k["state"] == "green"),
        "required_total": len(required_keys),
        "last_completed": mwg.iso(last_completed),
        "settle_left": max(0, int(settle - age)) if age is not None and age < settle else 0,
    }


def required_verdict(out):
    """The integration branch's health: only the REQUIRED push checks decide it (a red optional job
    is reported, it does not freeze anything). No settle time: a push run that finished is final."""
    req = [k for k in out["keys"] if k["required"]]
    for state in ("red", "pending", "missing"):
        if any(k["state"] == state for k in req):
            return state
    return "green" if req else "missing"


def important(gh, repo, head_branch, pattern, pr=None, since=None, max_pages=3):
    """Failed jobs on the PR's branch, since the PR was opened, matching the important pattern."""
    from urllib.parse import quote
    rx = re.compile(pattern, re.I)
    since_t = mwg.parse_time(since) if since else None
    runs = gh.list("repos/%s/actions/runs?branch=%s" % (repo, quote(head_branch, safe="")),
                   key="workflow_runs", max_pages=max_pages)
    found = []
    for r in runs:
        if r.get("event") not in ("pull_request", "push") or r.get("head_branch") != head_branch:
            continue
        created = mwg.parse_time(r.get("created_at"))
        if since_t and created and created < since_t:
            continue
        nums = [p.get("number") for p in r.get("pull_requests") or []]
        if pr and nums and pr not in nums:
            continue
        if r.get("conclusion") == "success" and int(r.get("run_attempt") or 1) == 1:
            continue
        for j in gh.list("repos/%s/actions/runs/%d/jobs?filter=all" % (repo, r["id"]), key="jobs"):
            if j.get("conclusion") not in ("failure", "timed_out"):
                continue
            failed_steps = [s.get("name") or "" for s in j.get("steps") or [] if s.get("conclusion") == "failure"]
            names = [j.get("name") or "", r.get("name") or ""] + failed_steps
            if any(rx.search(n) for n in names):
                found.append({"workflow": _wf(r.get("path")), "job": j.get("name"), "steps": failed_steps[:3],
                              "run_id": r["id"], "attempt": j.get("run_attempt"), "sha": r.get("head_sha")})
    return found


def evaluate(gh, repo, sha, event, required, branch=None, state_workflows=(), settle=120,
             important_pattern=None, head_branch=None, pr=None, since=None):
    runs = collect(gh, repo, sha, event, branch)
    checks, statuses = collect_external(gh, repo, sha)
    out = verdict(runs, required, checks, statuses, state_workflows, settle)
    if important_pattern and head_branch:
        out["important"] = important(gh, repo, head_branch, important_pattern, pr, since)
    else:
        out["important"] = []
    return out


def render(out):
    lines = ["%s  required %d/%d green%s" % (out["verdict"].upper(), out["required_green"], out["required_total"],
                                              (", settle %ds left" % out["settle_left"]) if out["settle_left"] else "")]
    for k in ("red", "pending", "missing"):
        for x in out[k]:
            lines.append("  %-8s %s" % (k, x))
    for x in out.get("important") or []:
        lines.append("  important %s / %s failed (run %s attempt %s)" % (x["workflow"], x["job"], x["run_id"], x["attempt"]))
    return "\n".join(lines)


def main(argv):
    spec = {"repo": "v", "sha": "v", "event": "v", "branch": "v", "required": "v", "state_workflows": "v",
            "important": "v", "head_branch": "v", "pr": "v", "since": "v", "settle": "v", "json": "flag",
            "help": "flag"}
    try:
        a, pos = mwg.parse_args(argv, spec)
        if a["help"]:
            print(__doc__)
            return 0
        if pos:
            raise mwg.UsageError("unexpected argument %r" % pos[0])
        repo = mwg.repo_arg(a["repo"])
        sha = mwg.sha_arg(a["sha"])
        if a["event"] not in ("pull_request", "push"):
            raise mwg.UsageError("--event must be pull_request or push")
        if a["event"] == "push" and not a["branch"]:
            raise mwg.UsageError("--event push needs --branch")
        try:
            required = json.loads(a["required"] or "")
            state_wf = json.loads(a["state_workflows"] or "[]")
        except ValueError:
            raise mwg.UsageError("--required/--state-workflows must be JSON")
        _, probs = mwg.validate_config({"version": 1, "required_checks": required, "required_push_checks": required})
        if probs:
            raise mwg.UsageError("; ".join(probs))
        settle = int(a["settle"] or 120)
        pattern = a["important"]
        if pattern:
            re.compile(pattern)
        gh = mwg.GH(os.environ.get("MWG_READ_TOKEN") or None)
        out = evaluate(gh, repo, sha, a["event"], required, a["branch"], state_wf, settle, pattern,
                       a["head_branch"], int(a["pr"]) if a["pr"] else None, a["since"])
        out["api_calls"] = gh.calls
    except mwg.UsageError as e:
        print("ci-verdict: %s" % e, file=sys.stderr)
        return 2
    except (mwg.ApiError, re.error, ValueError) as e:
        print("ci-verdict: could not measure: %s" % e, file=sys.stderr)
        return 2
    except Exception as e:  # fail closed on an unexpected answer
        print("ci-verdict: could not measure (%s: %s)" % (type(e).__name__, e), file=sys.stderr)
        return 2
    print(json.dumps(out, sort_keys=True) if a["json"] else render(out))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
