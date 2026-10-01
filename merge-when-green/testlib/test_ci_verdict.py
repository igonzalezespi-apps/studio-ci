"""Cases for ci_verdict.py: reds, pendings, skips, re-runs and the keys that used to hide a red."""
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import harness as H  # noqa: E402
from harness import job, run  # noqa: E402

S = H.Suite("ci-verdict")
SCRIPT = "merge-when-green/ci-verdict.sh"
SHA = H.sha(1)
REQ = [{"workflow": "ci.yml", "job": "test"}]


def verdict(label, runs, want, required=REQ, checks=(), statuses=(), state=(), settle="120", extra=(), world=None,
            register=True):
    w = world or H.World()
    if register:
        w.runs(SHA, runs)
    w.checks(SHA, checks, statuses)
    res = H.run_script(SCRIPT, ["--repo", H.REPO, "--sha", SHA, "--event", "pull_request", "--required",
                                json.dumps(required), "--state-workflows", json.dumps(list(state)),
                                "--settle", settle, "--json"] + list(extra), w)
    try:
        out = json.loads(res["out"])
    except ValueError:
        S.check(label, False, res["err"] or res["out"])
        return None
    S.check("%s -> %s" % (label, want), out["verdict"] == want, "got %s (red %s, pending %s, missing %s)" % (
        out["verdict"], out["red"], out["pending"], out["missing"]))
    return out


PR = "pull_request"
B = "feat/x"
verdict("all required green and settled", [run(1, "ci.yml", PR, B, SHA, [job("test")])], "green")
verdict("zero runs is not green", [], "missing")
verdict("failure then skipped (later runs only skip) is red",
        [run(1, "ci.yml", PR, B, SHA, [job("test", "failure")], created="2026-10-01T10:00:00Z"),
         run(2, "ci.yml", PR, B, SHA, [job("test", "skipped")], created="2026-10-01T10:10:00Z")], "red")
verdict("failure, then success on a re-run of the SAME run, is green",
        [run(1, "ci.yml", PR, B, SHA, [job("test", "failure", attempt=1), job("test", "success", attempt=2,
                                                                                 started="2026-10-01T11:10:00Z")])],
        "green")
verdict("failure, then SKIPPED on a re-run of the same run (an optional job), is red",
        [run(1, "ci.yml", PR, B, SHA, [job("test"), job("lint", "failure", attempt=1),
                                       job("lint", "skipped", attempt=2, steps=[], started="2026-10-01T11:10:00Z")])],
        "red")
verdict("failure, then SKIPPED on a re-run of the same run (the required job), is red",
        [run(1, "ci.yml", PR, B, SHA, [job("test", "failure", attempt=1),
                                       job("test", "skipped", attempt=2, steps=[], started="2026-10-01T11:10:00Z")])],
        "red")
verdict("success, then SKIPPED on a re-run, stays green",
        [run(1, "ci.yml", PR, B, SHA, [job("test", attempt=1),
                                       job("test", "skipped", attempt=2, steps=[], started="2026-10-01T11:10:00Z")])],
        "green")
verdict("failure in one run, success in ANOTHER run of the same workflow, stays red",
        [run(1, "ci.yml", PR, B, SHA, [job("test", "failure")], created="2026-10-01T10:00:00Z"),
         run(2, "ci.yml", PR, B, SHA, [job("test")], created="2026-10-01T10:10:00Z")], "red")
verdict("...unless the workflow re-reads live state (state_workflows): the latest run wins",
        [run(1, "ci.yml", PR, B, SHA, [job("test")]),
         run(2, "pr-tldr.yml", PR, B, SHA, [job("check-pr-tldr", "failure")], created="2026-10-01T10:00:00Z"),
         run(3, "pr-tldr.yml", PR, B, SHA, [job("check-pr-tldr")], created="2026-10-01T10:10:00Z")],
        "green", state=["pr-tldr.yml"])
verdict("state workflow whose latest run is red",
        [run(1, "ci.yml", PR, B, SHA, [job("test")]),
         run(2, "pr-tldr.yml", PR, B, SHA, [job("check-pr-tldr")], created="2026-10-01T10:00:00Z"),
         run(3, "pr-tldr.yml", PR, B, SHA, [job("check-pr-tldr", "failure")], created="2026-10-01T10:10:00Z")],
        "red", state=["pr-tldr.yml"])
verdict("an old cancelled run superseded by a newer success is green",
        [run(1, "ci.yml", PR, B, SHA, [job("test", "cancelled")], created="2026-10-01T10:00:00Z"),
         run(2, "ci.yml", PR, B, SHA, [job("test")], created="2026-10-01T10:10:00Z")], "green")
verdict("a cancelled run with nothing after it is red",
        [run(1, "ci.yml", PR, B, SHA, [job("test")], created="2026-10-01T10:00:00Z"),
         run(2, "ci.yml", PR, B, SHA, [job("test", "cancelled")], created="2026-10-01T10:10:00Z")], "red")
verdict("same job name in two workflows: success in one, failure in the other",
        [run(1, "ci.yml", PR, B, SHA, [job("test")]), run(2, "gates.yml", PR, B, SHA, [job("test", "failure")])], "red")
verdict("a failed step inside a successful job (continue-on-error) is red",
        [run(1, "ci.yml", PR, B, SHA, [job("test", steps=[{"name": "audit", "status": "completed",
                                                          "conclusion": "failure"}])])], "red")
verdict("required job only skipped is missing (a run success with the job skipped)",
        [run(1, "ci.yml", PR, B, SHA, [job("test", "skipped"), job("lint")])], "missing")
verdict("required job only neutral is missing", [run(1, "ci.yml", PR, B, SHA, [job("test", "neutral")])], "missing")
verdict("a neutral job nobody requires is fine",
        [run(1, "ci.yml", PR, B, SHA, [job("test"), job("extra", "neutral")])], "green")
verdict("an unknown conclusion is red (whitelist)", [run(1, "ci.yml", PR, B, SHA, [job("test", "stale")])], "red")
verdict("a job in progress is pending",
        [run(1, "ci.yml", PR, B, SHA, [job("test", status="in_progress")])], "pending")
verdict("required job absent is missing", [run(1, "ci.yml", PR, B, SHA, [job("lint")])], "missing")
verdict("green but completed 30 s ago is unsettled",
        [run(1, "ci.yml", PR, B, SHA, [job("test", completed="2026-10-01T11:59:30Z")])], "unsettled")
verdict("an optional job red anywhere makes it red",
        [run(1, "ci.yml", PR, B, SHA, [job("test"), job("docs", "failure")])], "red")
verdict("a push run of the same commit does not count for the PR",
        [run(1, "ci.yml", PR, B, SHA, [job("test")]), run(2, "ci.yml", "push", B, SHA, [job("test", "failure")])],
        "green")
verdict("a workflow_run-triggered run on the commit does not count",
        [run(1, "ci.yml", PR, B, SHA, [job("test")]), run(2, "mwg.yml", "workflow_run", B, SHA, [job("mwg", "failure")])],
        "green")
verdict("another App's failed check run is red", [run(1, "ci.yml", PR, B, SHA, [job("test")])], "red",
        checks=[{"id": 5, "name": "codecov", "app": {"slug": "codecov"}, "status": "completed", "conclusion": "failure",
                 "completed_at": "2026-10-01T11:00:00Z"}])
verdict("a github-actions check run is not counted twice", [run(1, "ci.yml", PR, B, SHA, [job("test")])], "green",
        checks=[{"id": 5, "name": "test", "app": {"slug": "github-actions"}, "status": "completed",
                 "conclusion": "failure"}])
verdict("a pending commit status (Renovate stability days) is pending", [run(1, "ci.yml", PR, B, SHA, [job("test")])],
        "pending", statuses=[{"context": "renovate/stability-days", "state": "pending"}])
verdict("a failed commit status is red", [run(1, "ci.yml", PR, B, SHA, [job("test")])], "red",
        statuses=[{"context": "ext", "state": "error"}])

# 101 runs over two pages, the red one on the second page
w = H.World()
page1 = [run(i, "w%d.yml" % i, PR, B, SHA, [job("j")]) for i in range(1, 101)]
page2 = [run(101, "ci.yml", PR, B, SHA, [job("test", "failure")])]
w.runs(SHA, page1 + page2)
w.pages("repos/%s/actions/runs?head_sha=%s&per_page=100" % (H.REPO, SHA),
        [{"workflow_runs": [H.strip(r) for r in page1]}, {"workflow_runs": [H.strip(r) for r in page2]}])
verdict("the red run on page 2 is seen", page1 + page2, "red", world=w, register=False)

# important: a security check that failed earlier in the PR's life, then passed
w = H.World()
hist = [run(50, "security.yml", PR, B, H.sha(2), [job("gitleaks", "failure")], created="2026-10-01T10:30:00Z", prs=[7]),
        run(51, "security.yml", PR, B, H.sha(2), [job("gitleaks", "failure", attempt=1),
                                                  job("gitleaks", "success", attempt=2)], created="2026-10-01T10:31:00Z", prs=[7]),
        run(40, "security.yml", PR, B, H.sha(3), [job("gitleaks", "failure")], created="2026-09-01T10:00:00Z", prs=[3]),
        run(41, "security.yml", "push", B, H.sha(3), [job("gitleaks", "failure")], created="2026-09-01T10:00:00Z")]
w.branch_history(B, hist)
out = verdict("important: green now", [run(1, "ci.yml", PR, B, SHA, [job("test")])], "green", world=w,
              extra=["--important", "gitleaks|secur", "--head-branch", B, "--pr", "7", "--since", "2026-10-01T10:00:00Z"])
S.check("important: the earlier security failure is reported", out and len(out["important"]) == 2,
        out and out["important"])
S.check("important: a failure from an older PR on the same branch name is ignored",
        out and all(x["run_id"] not in (40, 41) for x in out["important"]), out and out["important"])
S.check("important: a red that a re-run turned green (the run now says success) is still reported",
        out and any(x["run_id"] == 51 for x in out["important"]), out and out["important"])
w = H.World()
w.branch_history(B, [run(52, "security.yml", PR, B, H.sha(2), [job("gitleaks", "timed_out")],
                         created="2026-10-01T10:30:00Z", prs=[7])])
out = verdict("important: a timed-out security job", [run(1, "ci.yml", PR, B, SHA, [job("test")])], "green", world=w,
              extra=["--important", "gitleaks|secur", "--head-branch", B, "--pr", "7", "--since", "2026-10-01T10:00:00Z"])
S.check("important: a timed-out security job counts as failed", out and len(out["important"]) == 1, out and out["important"])

# usage
for label, args in (("--repo without value", ["--sha", SHA, "--repo"]),
                    ("short sha", ["--repo", H.REPO, "--sha", "abc", "--event", "push", "--branch", "d", "--required", "[]"]),
                    ("push without branch", ["--repo", H.REPO, "--sha", SHA, "--event", "push", "--required", json.dumps(REQ)]),
                    ("empty required", ["--repo", H.REPO, "--sha", SHA, "--event", PR, "--required", "[]"])):
    p = subprocess.run(["timeout", "5", os.path.join(H.ROOT, SCRIPT)] + args, capture_output=True, text=True)
    S.check("usage: %s -> exit 2" % label, p.returncode == 2, p.returncode)

w = H.World()
w.routes["GET repos/%s/actions/runs?head_sha=%s&per_page=100" % (H.REPO, SHA)] = {"status": 500, "body": {"message": "x"}}
res = H.run_script(SCRIPT, ["--repo", H.REPO, "--sha", SHA, "--event", PR, "--required", json.dumps(REQ)], w)
S.check("API error -> exit 2 (never a verdict)", res["rc"] == 2, res)


w = H.World(); w.runs(SHA, [run(1, "ci.yml", PR, B, SHA, [job("test", "failure")])]); w.checks(SHA)
res = H.run_script(SCRIPT, ["--repo", H.REPO, "--sha", SHA, "--event", PR, "--required", json.dumps(REQ)], w)
S.check("text output: verdict and the red key", res["rc"] == 0 and res["out"].startswith("RED") and "ci.yml / test" in res["out"], res["out"])

sys.exit(S.done())
