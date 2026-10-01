"""Cases for develop_health.py: green, pending, infrastructure reds, the re-run, attribution to ONE
automatic merge, and every reason it escalates instead of reverting."""
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "merge-when-green", "testlib"))
import harness as H  # noqa: E402
from harness import job, run  # noqa: E402

S = H.Suite("develop-health")
DH = "develop-health/develop-health.sh"
R = H.REPO
APP_BOT = "%s[bot]" % H.APP
FREEZE_LIST = "repos/%s/issues?state=open&labels=merge-freeze&per_page=100" % R
L, F, G = H.sha(100), H.sha(101), H.sha(102)


def world(pushes, head=None, freeze=(), reverts=(), **cfg):
    """pushes: newest first, (sha, conclusion | jobs, attempt)."""
    w = H.World()
    w.policy()
    w.config(**cfg)
    w.workflows({"ci.yml": "", "develop-health.yml": ""})
    runs = []
    for i, (s, concl, attempt) in enumerate(pushes):
        jobs_ = concl if isinstance(concl, list) else [job("test", concl, attempt=attempt)]
        runs.append(run(700 + i, "ci.yml", "push", "develop", s, jobs_, attempt=attempt,
                        created="2026-10-01T%02d:00:00Z" % (11 - i)))
    w.branch_history("develop", runs, extra="&event=push")
    head = head or (pushes[0][0] if pushes else H.sha(999))
    w.r("GET", "repos/%s/commits/develop" % R, {"sha": head, "commit": {"committer": {"date": "2026-10-01T11:30:00Z"}}})
    w.r("GET", FREEZE_LIST, list(freeze))
    w.r("GET", "repos/%s/pulls?state=all&sort=created&direction=desc&per_page=50&page=1" % R, list(reverts))
    return w


def culprit(w, n=4, merged_by=APP_BOT, trailer=0, labels=("riesgo:0",), title="docs: x", commits=(F,), parents=1,
            body="", behind=0):
    cs = [{"sha": c, "parents": [{"sha": "p"}] * parents,
           "commit": {"message": "%s (#%d)\n\nRisk-class: riesgo:%d\nMerge-gate: merge-when-green https://x/run/0\n"
                      % (title, n, trailer) if trailer is not None else "%s (#%d)" % (title, n)}} for c in commits]
    w.r("GET", "repos/%s/compare/%s...%s" % (R, L, F), {"behind_by": behind, "ahead_by": len(cs), "commits": cs})
    w.pages("repos/%s/commits/%s/pulls?per_page=100" % (R, F), [[{
        "number": n, "title": "%s" % title, "merge_commit_sha": F, "merged_at": "2026-10-01T10:00:00Z",
        "merged_by": {"login": merged_by}, "labels": [{"name": x} for x in labels], "body": body}]])
    w.comments(n, [])
    # what merge-when-green reads about the original when it judges the revert
    w.pull(n, title=title, state="closed", merged_at="2026-10-01T10:00:00Z", merge_commit_sha=F, merged_by=merged_by)
    w.files(n, ["docs/a.md"])


def open_revert(w, n=31, ci="success", mergeable=True, created="2026-10-01T11:00:00Z", commits=None, state="open"):
    """The App's revert of #4, as merge-when-green would judge it (develop-health re-judges it)."""
    w.r("GET", "repos/%s/commits/%s" % (R, F), {"sha": F, "parents": [{"sha": L}],
                                               "commit": {"message": "docs: x (#4)\n\nRisk-class: riesgo:0\n"
                                                                     "Merge-gate: merge-when-green https://x/run/0\n"}})
    p = w.pull(n, title="revert: docs: x (#4)", author=APP_BOT, labels=("revert-on-red", "riesgo:0", "semver:none"),
               body="<!-- revert-of: #4 sha: %s -->\nReverts #4" % F, created=created, mergeable=mergeable, state=state)
    s_ = p["head"]["sha"]
    jobs_ = [job("test", status="in_progress")] if ci == "pending" else [job("test", ci)]
    w.runs(s_, [run(1031, "ci.yml", "pull_request", p["head"]["ref"], s_, jobs_)])
    w.checks(s_)
    w.events(n)
    w.commits(n, commits or [{"author": APP_BOT, "committer": "web-flow", "message": "revert", "verified": True}])
    w.files(n, ["docs/a.md"])
    w.file("docs/a.md", "before\n", ref=L)
    w.file("docs/a.md", "before\n", ref=s_)
    return {"number": n, "user": {"login": APP_BOT}, "body": "<!-- revert-of: #4 sha: %s -->" % F,
            "created_at": created, "state": state, "merged_at": None, "head": {"repo": {"full_name": R}}}


def assess(w, mode="live"):
    plan = os.path.join(os.environ.get("TMPDIR", "/tmp"), "dh-plan-%d.json" % os.getpid())
    res = H.run_script(DH, ["--repo", R, "--mode", mode, "--plan", plan, "--run-url", "https://x/run/3"], w)
    try:
        res["plan"] = json.load(open(plan))
    except (OSError, ValueError):
        res["plan"] = {"action": "?", "err": res["err"]}
    if os.path.exists(plan):
        os.unlink(plan)
    return res


def expect(label, w, action, mode="live", note=None):
    res = assess(w, mode)
    ok = res["rc"] == 0 and res["plan"].get("action") == action
    if ok and note:
        ok = note in json.dumps(res["plan"])
    S.check("%s -> %s" % (label, action), ok, (res["plan"].get("action"), res["plan"].get("notes"), res["err"]))
    return res


BOT_FREEZE = {"number": 40, "user": {"login": "github-actions[bot]"}, "body": "<!-- develop-health v1 freeze -->\nx",
              "labels": [{"name": "merge-freeze"}]}

# ── green, pending, stalled ──────────────────────────────────────────────────────────────────────
res = expect("green, nothing frozen", world([(G, "success", 1)]), "none")
S.check("green: no write", not H.writes(res))
res = expect("green with its own freeze open: recover and close", world([(G, "success", 1)], freeze=[BOT_FREEZE]), "recover")
S.check("recover: merge-freeze label removed", any(c["method"] == "DELETE" and "labels/merge-freeze" in c["path"] for c in H.writes(res)))
S.check("recover: the plain freeze is closed", any(c["method"] == "PATCH" and c["input"] == {"state": "closed"} for c in H.writes(res)))
esc = dict(BOT_FREEZE, labels=[{"name": "merge-freeze"}, {"name": "revision-humana"}])
res = expect("green with an ESCALATED freeze: unfreeze but keep it open for the owner", world([(G, "success", 1)], freeze=[esc]),
             "recover")
S.check("recover: an escalated freeze is not closed", not any(c["method"] == "PATCH" for c in H.writes(res)))
openrev = {"number": 31, "user": {"login": APP_BOT}, "body": "<!-- revert-of: #4 sha: %s -->" % F,
           "created_at": "2026-10-01T11:00:00Z", "state": "open", "merged_at": None, "head": {"repo": {"full_name": R}}}
res = expect("green again with the App's revert still open: close it", world([(G, "success", 1)], freeze=[BOT_FREEZE],
             reverts=[openrev]), "recover", note="closed revert #31")
S.check("recover: the stale revert is closed, not merged", any(c["method"] == "PATCH" and c["path"].endswith("/pulls/31")
        and c["input"] == {"state": "closed"} for c in H.writes(res)), H.writes(res))
res = expect("a freeze opened by someone else is not touched", world([(G, "success", 1)],
             freeze=[dict(BOT_FREEZE, user={"login": "stranger"})]), "none")
expect("pending", world([(G, [job("test", status="in_progress")], 1)]), "wait")
w = world([(L, "success", 1)], head=G)
w.r("GET", "repos/%s/commits/develop" % R, {"sha": G, "commit": {"committer": {"date": "2026-10-01T09:00:00Z"}}})
expect("a head with no push run for over an hour", w, "wait", note="stalled")
res = expect("a red job that is not a required push check", world([(G, [job("test"), job("docs", "failure")], 1)]),
             "none", note="not a required push check")

# ── infrastructure ───────────────────────────────────────────────────────────────────────────────
res = expect("a job that never ran (0 steps)", world([(G, [job("test", "failure", steps=[])], 1), (L, "success", 1)]), "infra")
S.check("infra: never reverted, no rerun of a plain failure", not H.writes(res))
res = expect("startup_failure: re-run once", world([(G, "startup_failure", 1), (L, "success", 1)]), "infra")
S.check("startup_failure: whole run re-run", any(c["path"].endswith("/runs/700/rerun") for c in H.writes(res, "POST")))
expect("cancelled (concurrency or billing) is infrastructure", world([(G, "cancelled", 1), (L, "success", 1)]), "infra")

# ── real red ─────────────────────────────────────────────────────────────────────────────────────
res = expect("real red, first attempt: re-run the failed jobs", world([(F, "failure", 1), (L, "success", 1)]), "rerun")
S.check("rerun-failed-jobs requested", any(c["path"].endswith("/runs/700/rerun-failed-jobs") for c in H.writes(res, "POST")))

w = world([(F, "failure", 2), (L, "success", 1)]); culprit(w)
res = expect("red again, one automatic riesgo-0 commit: revert", w, "revert")
S.check("revert: outputs the PR and the commit", res["outputs"].get("revert_pr") == "4" and res["outputs"].get("revert_sha") == F,
        res["outputs"])
S.check("revert: a freeze issue is opened", any(c["path"].endswith("/issues") and "merge-freeze" in json.dumps(c["input"])
                                                for c in H.writes(res, "POST")))
S.check("revert: the culprit PR is told", any(c["path"].endswith("/issues/4/comments") for c in H.writes(res, "POST")))
S.check("revert: develop-health itself does not open the revert (the App job does)",
        not any(c["path"] == "graphql" for c in res["calls"]))

w = world([(G, "failure", 2), (F, "failure", 2), (L, "success", 1)]); culprit(w)
res = expect("the FIRST red push after the last green is the culprit, not the head", w, "revert")
S.check("first red attributed", res["outputs"].get("revert_sha") == F, res["outputs"])

w = world([(F, "failure", 2), (L, "success", 1)]); culprit(w, commits=(H.sha(55), F))
res = expect("two commits between green and red: escalate", w, "escalate", note="not attributable")
S.check("escalate: the freeze issue carries revision-humana and a TL;DR",
        any(c["path"].endswith("/issues") and "revision-humana" in json.dumps(c["input"]) and "## TL;DR" in c["input"]["body"]
            for c in H.writes(res, "POST")))
w = world([(F, "failure", 2), (G, "cancelled", 1), (L, "success", 1)]); culprit(w, commits=(G, F))
expect("an unmeasured (cancelled) push in between: escalate", w, "escalate")
w = world([(F, "failure", 2), (L, "success", 1)]); culprit(w, merged_by="igonzalezespi")
expect("a person's merge is never reverted", w, "escalate", note="never reverted automatically")
w = world([(F, "failure", 2), (L, "success", 1)]); culprit(w, labels=("revert-on-red",), title="revert: docs: y")
expect("never revert a revert", w, "escalate", note="never revert a revert")
w = world([(F, "failure", 2), (L, "success", 1)]); culprit(w, trailer=None)
expect("no Risk-class trailer", w, "escalate", note="trailer")
w = world([(F, "failure", 2), (L, "success", 1)]); culprit(w, trailer=3)
expect("a riesgo-3 trailer", w, "escalate", note="trailer")
w = world([(F, "failure", 2), (L, "success", 1)]); culprit(w, parents=2)
expect("a merge commit (two parents)", w, "escalate", note="merge commit")
recent = {"number": 30, "user": {"login": APP_BOT}, "body": "<!-- revert-of: #3 sha: %s -->" % H.sha(3),
          "created_at": "2026-10-01T08:00:00Z", "state": "closed", "merged_at": "2026-10-01T08:30:00Z",
          "head": {"repo": {"full_name": R}}}
w = world([(F, "failure", 2), (L, "success", 1)], reverts=[recent]); culprit(w)
expect("one revert already in the last 24 h: escalate", w, "escalate", note="last 24 h")
w = world([(F, "failure", 2), (L, "success", 1)], reverts=[dict(recent, created_at="2026-09-29T08:00:00Z")]); culprit(w)
expect("an older revert does not count against the cap", w, "revert")
mine = dict(recent, number=31, body="<!-- revert-of: #4 sha: %s -->" % F, state="open", merged_at=None)
w = world([(F, "failure", 2), (L, "success", 1)], freeze=[BOT_FREEZE]); culprit(w)
w.r("GET", "repos/%s/pulls?state=all&sort=created&direction=desc&per_page=50&page=1" % R, [open_revert(w)])
res = expect("the revert is open, valid and green: wait for merge-when-green", w, "wait", note="is open (merge")
S.check("idempotent: no second freeze or revert", not H.writes(res, "POST") or
        not any(c["path"].endswith("/issues") for c in H.writes(res, "POST")))
w = world([(F, "failure", 2), (L, "success", 1)], freeze=[BOT_FREEZE]); culprit(w)
w.r("GET", "repos/%s/pulls?state=all&sort=created&direction=desc&per_page=50&page=1" % R, [open_revert(w, ci="pending")])
expect("the revert is open with CI pending: wait", w, "wait", note="is open (wait")
w = world([(F, "failure", 2), (L, "success", 1)], freeze=[BOT_FREEZE]); culprit(w)
w.r("GET", "repos/%s/pulls?state=all&sort=created&direction=desc&per_page=50&page=1" % R, [open_revert(w, ci="failure")])
res = expect("the revert's own CI is red: escalate", w, "escalate", note="cannot be merged automatically")
S.check("escalated revert: the freeze gets revision-humana", any(c["path"].endswith("/issues/40/labels") and
        c["input"] == {"labels": ["revision-humana"]} for c in H.writes(res, "POST")), H.writes(res))
w = world([(F, "failure", 2), (L, "success", 1)], freeze=[BOT_FREEZE]); culprit(w)
w.r("GET", "repos/%s/pulls?state=all&sort=created&direction=desc&per_page=50&page=1" % R, [open_revert(w, mergeable=False)])
expect("the revert is in conflict: escalate", w, "escalate", note="conflicts")
w = world([(F, "failure", 2), (L, "success", 1)], freeze=[BOT_FREEZE]); culprit(w)
w.r("GET", "repos/%s/pulls?state=all&sort=created&direction=desc&per_page=50&page=1" % R,
    [open_revert(w, commits=[{"author": APP_BOT, "committer": "web-flow", "message": "revert", "verified": True},
                             {"author": "dev", "committer": "dev", "message": "fix", "verified": False}])])
expect("a commit pushed on top of the revert: escalate", w, "escalate", note="invalid revert")
w = world([(F, "failure", 2), (L, "success", 1)], freeze=[BOT_FREEZE]); culprit(w)
w.r("GET", "repos/%s/pulls?state=all&sort=created&direction=desc&per_page=50&page=1" % R,
    [open_revert(w, created="2026-10-01T09:30:00Z")])
expect("the revert has been open for more than two hours: escalate", w, "escalate", note="has been open")
w = world([(F, "failure", 2), (L, "success", 1)], reverts=[dict(mine, state="closed")]); culprit(w)
expect("the revert was closed without merging: escalate", w, "escalate", note="closed without merging")
w = world([(F, "failure", 2), (L, "success", 1)], freeze=[BOT_FREEZE]); culprit(w)
w.r("GET", "repos/%s/pulls?state=all&sort=created&direction=desc&per_page=50&page=1" % R, [open_revert(w)])
w.pull(31, state="closed", author=APP_BOT)
expect("the revert closed between the list and the read: escalate", w, "escalate", note="without merging")
w = world([(F, "failure", 2), (L, "success", 1)], reverts=[dict(mine, state="closed", merged_at="2026-10-01T11:00:00Z")])
culprit(w)
expect("reverted and still red: escalate", w, "escalate", note="already reverted")
forged = dict(mine, user={"login": "stranger"})
w = world([(F, "failure", 2), (L, "success", 1)], reverts=[forged]); culprit(w)
expect("a forged revert-of marker by someone else does not stop the revert", w, "revert")
w = world([(F, "failure", 2), (L, "success", 1)], reverts=[dict(mine, head={"repo": {"full_name": "evil/fork"}})]); culprit(w)
expect("an App-looking revert from a fork does not count", w, "revert")
w = world([(F, "failure", 2), (L, "success", 1)]); culprit(w, behind=1)
expect("the first red is not a descendant of the last green (behind_by): escalate", w, "escalate", note="not attributable")
w = world([(F, [job("test", "failure", attempt=1), job("test", "skipped", attempt=2, steps=[])], 2), (L, "success", 1)])
culprit(w)
res = expect("failure then SKIPPED on the re-run: still red, attributed (not re-run again)", w, "revert")
S.check("failure then SKIPPED: no second re-run", not any("rerun" in c["path"] for c in H.writes(res)), H.writes(res))
w = world([(G, [job("test", "failure", steps=[]), job("test2", "failure")], 1), (L, "success", 1)], required_push_checks=[
    {"workflow": "ci.yml", "job": "test"}, {"workflow": "ci.yml", "job": "test2"}])
expect("one infrastructure red and one real red is a real red", w, "rerun")
w = world([(F, "failure", 2), (G, "failure", 2)]); culprit(w)
expect("no green push in the window: escalate", w, "escalate", note="no green push")


# ── more edges ───────────────────────────────────────────────────────────────────────────────────
w = world([(F, "failure", 2), (L, "success", 1)], freeze=[esc]); culprit(w, merged_by="igonzalezespi")
res = expect("a freeze already escalated is not rewritten on every run", w, "escalate", note="already with the owner")
S.check("already escalated: no write on the freeze", not any("/issues/40" in c["path"] for c in H.writes(res)), H.writes(res))
w = world([(F, "failure", 2), (L, "success", 1)], freeze=[BOT_FREEZE]); culprit(w, merged_by="igonzalezespi")
res = expect("escalating an existing freeze edits it and adds revision-humana", w, "escalate")
S.check("existing freeze: body rewritten with the TL;DR, label added",
        any(c["method"] == "PATCH" and c["path"].endswith("/issues/40") and "## TL;DR" in c["input"]["body"] for c in H.writes(res)) and
        any(c["path"].endswith("/issues/40/labels") and c["input"] == {"labels": ["revision-humana"]} for c in H.writes(res, "POST")))
w = world([(F, "failure", 2), (L, "success", 1)]); culprit(w)
mark = {"id": 88, "user": {"login": "github-actions[bot]"}, "created_at": H.T0, "updated_at": H.T0,
        "body": "<!-- develop-health v1 culprit head=%s -->\nold" % F[:7]}
w.comments(4, [mark])
res = expect("the culprit comment is not repeated for the same head", w, "revert")
S.check("culprit comment unchanged -> no write on it", not any("/issues/4/comments" in c["path"] or "/comments/88" in c["path"]
                                                              for c in H.writes(res)))
w.comments(4, [dict(mark, body="<!-- develop-health v1 culprit head=0000000 -->\nold")])
res = expect("the culprit comment is edited for a new head", w, "revert")
S.check("culprit comment edited", any(c["method"] == "PATCH" and c["path"].endswith("/comments/88") for c in H.writes(res)))
w = H.World(); w.policy(); w.workflows({"ci.yml": ""})
res = expect("no config: skip", w, "skip", note="no usable config")
w = world([(G, "success", 1)]); w.remaining = 100
expect("API quota low: wait", w, "wait", note="quota")
w = world([(F, [job("test", "failure", attempt=1), job("test", "failure", attempt=2)], 2), (L, "success", 1)])
w.r("GET", "repos/%s/compare/%s...%s" % (R, L, F), {"behind_by": 0, "commits": [{"sha": F, "parents": [{"sha": "p"}], "commit": {"message": "x"}}]})
w.pages("repos/%s/commits/%s/pulls?per_page=100" % (R, F), [[]])
expect("a commit pushed without a pull request: escalate", w, "escalate", note="does not belong to a merged pull request")

# ── dry ──────────────────────────────────────────────────────────────────────────────────────────
w = world([(F, "failure", 1), (L, "success", 1)]); culprit(w)
res = expect("dry: attempt 1 is not re-run, attribution is reported", w, "revert", mode="dry")
S.check("dry: no rerun, no issue, no revert", not [c for c in H.writes(res) if not c["path"].endswith("/issues/4/comments")],
        H.writes(res))
S.check("dry: the culprit gets the SECO comment", any("SECO" in json.dumps(c["input"]) for c in H.writes(res, "POST")))

# ── the owner's queue: one @mention per riesgo-3/4 PR that waited too long ───────────────────────────
# NOW is 2026-10-01T12:00:00Z (harness). Each PR: labels, when it was labelled revision-humana / marked
# ready, and the comments already on it.
def alert_world(prs, **kw):
    w = world([(G, "success", 1)], **kw)
    pulls = []
    for spec in prs:
        n = spec["n"]
        p = w.pull(n, labels=spec.get("labels", ()), draft=spec.get("draft", False), base=spec.get("base", "develop"),
                   head_ref=spec.get("head"), fork=spec.get("fork", False), created=spec.get("created", "2026-09-28T09:00:00Z"))
        pulls.append(p)
        ev = [{"event": "labeled", "label": {"name": "revision-humana"}, "created_at": spec["flagged"]}] if spec.get("flagged") else []
        if spec.get("ready"):
            ev.append({"event": "ready_for_review", "created_at": spec["ready"]})
        w.pages("repos/%s/issues/%d/events?per_page=100" % (R, n), [ev])
        w.comments(n, spec.get("comments", []))
    w.open_pulls(pulls)
    return w


def alert(w, mentions="owner", hours=None, mode="live", selftest=False):
    plan = os.path.join(os.environ.get("TMPDIR", "/tmp"), "dh-alert-%d.json" % os.getpid())
    args = ["--repo", R, "--mode", mode, "--plan", plan, "--run-url", "https://x/run/3"]
    if mentions is not None:
        args += ["--owner-alert", mentions]
    if hours:
        args += ["--owner-alert-hours", hours]
    if selftest:
        args += ["--selftest-config", os.path.join(H.ROOT, "merge-when-green", "selftest.json")]
    res = H.run_script(DH, args, w)
    res["plan"] = json.load(open(plan)) if os.path.exists(plan) else {}
    os.path.exists(plan) and os.unlink(plan)
    res["alerts"] = {a["pr"]: a["action"] for a in res["plan"].get("owner_alerts") or []}
    res["posted"] = [c for c in H.writes(res, "POST") if c["path"].endswith("/comments")]
    return res


def mention_on(res, n):
    return [c for c in res["posted"] if c["path"].endswith("/issues/%d/comments" % n)]


FLAG3 = {"labels": ("riesgo:3", "revision-humana", "semver:minor")}
res = alert(alert_world([dict(FLAG3, n=11, flagged="2026-09-30T10:00:00Z")]))
S.check("riesgo-3 flagged 26 h ago: one comment that @mentions the owner", res["rc"] == 0 and
        res["alerts"].get(11) == "alerted" and len(mention_on(res, 11)) == 1 and
        "@owner" in mention_on(res, 11)[0]["input"]["body"] and
        mention_on(res, 11)[0]["input"]["body"].startswith("<!-- owner-alert v1 class=3 "), (res["alerts"], res["err"]))
S.check("...and the branch's own verdict is untouched", res["plan"].get("action") == "none", res["plan"].get("action"))
res = alert(alert_world([dict(FLAG3, n=11, flagged="2026-10-01T02:00:00Z")]))
S.check("riesgo-3 flagged 10 h ago: waits, no comment", res["alerts"].get(11) == "waiting" and not res["posted"], res["alerts"])
res = alert(alert_world([{"n": 12, "labels": ("riesgo:4", "revision-humana"), "flagged": "2026-10-01T11:59:00Z"}]))
S.check("riesgo-4 flagged a minute ago: at once", res["alerts"].get(12) == "alerted" and len(mention_on(res, 12)) == 1, res["alerts"])
res = alert(alert_world([{"n": 13, "base": "main", "head": "develop", "created": "2026-10-01T11:00:00Z"}]))
S.check("a promotion into main is riesgo-4 by definition: at once", res["alerts"].get(13) == "alerted" and
        "class=4" in mention_on(res, 13)[0]["input"]["body"], res["alerts"])
res = alert(alert_world([{"n": 13, "base": "main", "head": "develop", "fork": True}]))
S.check("a 'promotion' from a fork is not one", 13 not in res["alerts"] and not res["posted"], res["alerts"])
res = alert(alert_world([{"n": 14, "labels": ("riesgo:2", "revision-humana"), "flagged": "2026-09-25T10:00:00Z"}]))
S.check("riesgo-2 flagged a week ago: weekly list only, no mention", 14 not in res["alerts"] and not res["posted"], res["alerts"])
res = alert(alert_world([{"n": 15, "labels": ("riesgo:3",), "created": "2026-09-25T10:00:00Z"}]))
S.check("riesgo-3 not flagged: not waiting on the owner", 15 not in res["alerts"] and not res["posted"], res["alerts"])
res = alert(alert_world([{"n": 16, "labels": ("riesgo:4", "revision-humana"), "flagged": "2026-09-25T10:00:00Z", "draft": True}]))
S.check("a draft is not ready for the owner", 16 not in res["alerts"] and not res["posted"], res["alerts"])
BOT_ALERT = {"id": 70, "user": {"login": "github-actions[bot]"}, "created_at": "2026-09-30T11:00:00Z",
             "updated_at": "2026-09-30T11:00:00Z", "body": "<!-- owner-alert v1 class=3 since=x -->\n@owner ..."}
res = alert(alert_world([dict(FLAG3, n=11, flagged="2026-09-29T10:00:00Z", comments=[BOT_ALERT])]))
S.check("already alerted in this spell: no second comment", res["alerts"].get(11) == "already alerted" and not res["posted"], res["alerts"])
res = alert(alert_world([dict(FLAG3, n=11, flagged="2026-09-30T10:00:00Z",
                              comments=[dict(BOT_ALERT, created_at="2026-09-29T08:00:00Z")])]))
S.check("an alert from an earlier spell (before the latest flag) does not count", res["alerts"].get(11) == "alerted", res["alerts"])
res = alert(alert_world([dict(FLAG3, n=11, flagged="2026-09-29T10:00:00Z", comments=[dict(BOT_ALERT, user={"login": "dev"})])]))
S.check("someone else's comment with the mark does not count", res["alerts"].get(11) == "alerted", res["alerts"])
res = alert(alert_world([{"n": 12, "labels": ("riesgo:4", "revision-humana"), "flagged": "2026-09-29T10:00:00Z",
                          "comments": [BOT_ALERT]}]))
S.check("the class rose from 3 to 4 since the alert: alert again", res["alerts"].get(12) == "alerted", res["alerts"])
res = alert(alert_world([dict(FLAG3, n=11, flagged="2026-09-29T10:00:00Z", ready="2026-10-01T10:00:00Z")]))
S.check("marked ready 2 h ago: the wait starts there", res["alerts"].get(11) == "waiting" and not res["posted"], res["alerts"])
w = alert_world([dict(FLAG3, n=11, flagged="2026-09-30T10:00:00Z")])
res = alert(w, mentions=None)
S.check("off by default: without --owner-alert the queue is not even read",
        not any("pulls?state=open" in (c["path"] or "") for c in res["calls"]) and not res["posted"], res["calls"][-3:])
res = alert(w, hours="3=48")
S.check("--owner-alert-hours 3=48: 26 h is not enough", res["alerts"].get(11) == "waiting" and not res["posted"], res["alerts"])
res = alert(w, mode="dry")
S.check("dry mode: the notice is written too (it is not an action on the code)", res["alerts"].get(11) == "alerted", res["alerts"])
res = alert(w, mode="dry", selftest=True)
S.check("self-test: never written", res["alerts"].get(11) == "would alert" and not H.writes(res), (res["alerts"], H.writes(res)))
many = [dict(FLAG3, n=20 + i, flagged="2026-09-29T10:00:00Z") for i in range(7)]
res = alert(alert_world(many))
S.check("at most 5 mentions per run, the rest next run", len(res["posted"]) == 5 and
        sorted(res["alerts"].values()).count("next run") == 2, res["alerts"])
res = alert(w, mentions="owner,bad login!")
S.check("a mention that is not a login: usage error, nothing read", res["rc"] == 2 and not res["calls"], res["err"])
res = alert(w, hours="2=5")
S.check("--owner-alert-hours only knows classes 3 and 4", res["rc"] == 2, res["err"])
# A session flags a PR when it opens it, and merge-when-green never classifies a held PR: no riesgo
# label. The alert classifies it with the same classifier and keeps the class as the label.
def unlabelled(n, files, flagged="2026-09-30T10:00:00Z"):
    return {"n": n, "labels": ("revision-humana", "semver:minor"), "flagged": flagged, "files": files}


def alert_world_files(prs):
    w = alert_world(prs)
    for spec in prs:
        if spec.get("files"):
            w.files(spec["n"], spec["files"])
            w.commits(spec["n"])
    return w


res = alert(alert_world_files([unlabelled(31, [".github/workflows/ci.yml"])]))
S.check("flagged, no riesgo label, a workflow change: classified riesgo-3, labelled, alerted",
        res["alerts"].get(31) == "alerted" and any(c["path"].endswith("/issues/31/labels") and
        c["input"] == {"labels": ["riesgo:3"]} for c in H.writes(res, "POST")), (res["alerts"], H.writes(res)))
res = alert(alert_world_files([unlabelled(32, ["CLAUDE.md"])]))
S.check("flagged, no riesgo label, riesgo-2 content: labelled, not alerted",
        32 not in res["alerts"] and not res["posted"] and any(c["path"].endswith("/issues/32/labels") and
        c["input"] == {"labels": ["riesgo:2"]} for c in H.writes(res, "POST")), (res["alerts"], H.writes(res)))
res = alert(alert_world_files([unlabelled(40 + i, ["CLAUDE.md"]) for i in range(6)]))
S.check("at most 5 classifications per run", sum(1 for c in H.writes(res, "POST") if c["path"].endswith("/labels")) == 5
        and list(res["alerts"].values()) == ["next run (not classified yet)"], res["alerts"])
res = alert(alert_world_files([unlabelled(31, [".github/workflows/ci.yml"])]), mode="dry", selftest=True)
S.check("self-test: classified but not labelled", res["alerts"].get(31) == "would alert" and not H.writes(res), H.writes(res))
w = alert_world([unlabelled(33, None)])
res = alert(w)
S.check("a PR it cannot classify is reported, the run goes on", res["rc"] == 0 and
        str(res["alerts"].get(33, "")).startswith("could not classify"), res["alerts"])

w = alert_world([])
w.r("GET", "repos/%s/pulls?state=open&per_page=100" % R, {"message": "boom"}, status=500)
res = alert(w)
S.check("the queue cannot be read: the branch's verdict still stands, and it says so",
        res["rc"] == 0 and res["plan"].get("action") == "none" and "owner alert" in json.dumps(res["plan"]["notes"]),
        (res["rc"], res["plan"].get("notes"), res["err"]))

# ── self-test: this repository's own CI reads a real repo and writes nothing at all ─────────────────
SC = os.path.join(H.ROOT, "merge-when-green", "selftest.json")
VA = "validate actions"  # the job selftest.json requires
w = world([(F, [job(VA, "failure", attempt=2)], 2), (L, [job(VA)], 1)]); culprit(w, merged_by="igonzalezespi")
w.routes.pop("GET repos/%s/contents/.github/merge-when-green.json?ref=develop" % R)
plan = os.path.join(os.environ.get("TMPDIR", "/tmp"), "dh-st-%d.json" % os.getpid())
res = H.run_script(DH, ["--repo", R, "--mode", "dry", "--plan", plan, "--selftest-config", SC], w)
st_plan = json.load(open(plan)) if os.path.exists(plan) else {}
S.check("self-test: red develop with a culprit is judged (escalate) and nothing is written",
        res["rc"] == 0 and st_plan.get("action") == "escalate" and not H.writes(res),
        (res["rc"], st_plan.get("action"), res["err"], H.writes(res)))
res = H.run_script(DH, ["--repo", R, "--mode", "live", "--plan", plan, "--selftest-config", SC], w)
S.check("self-test refuses live", res["rc"] == 2 and not H.writes(res), res["err"])
os.path.exists(plan) and os.unlink(plan)

sys.exit(S.done())
