"""Cases for revert_merge.py: it reverts only an App's squash of riesgo-0..2, once, with the App token."""
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "merge-when-green", "testlib"))
import harness as H  # noqa: E402

S = H.Suite("revert-merge")
RM = "revert-merge/revert-merge.sh"
R = H.REPO
F = H.sha(101)
APP_BOT = "%s[bot]" % H.APP
APP_ENV = {"GITHUB_ACTIONS": "true", "MWG_WRITE_TOKEN_KIND": "app", "MWG_WRITE_TOKEN": "ghs_apptoken",
           "MWG_READ_TOKEN": "ghs_readtoken"}


def world(merged_by=APP_BOT, sha=F, parents=1, trailer=0, existing=()):
    w = H.World()
    w.pull(4, title="docs: x (#4)", state="closed", merged_at="2026-10-01T10:00:00Z", merge_commit_sha=sha,
           merged_by=merged_by)
    msg = "docs: x (#4)\n\nRisk-class: riesgo:%d\n" % trailer if trailer is not None else "docs: x (#4)"
    w.r("GET", "repos/%s/commits/%s" % (R, F), {"sha": F, "parents": [{"sha": "p"}] * parents, "commit": {"message": msg}})
    w.r("GET", "repos/%s/pulls?state=all&sort=created&direction=desc&per_page=50&page=1" % R, list(existing))
    w.r("GET", "installation/repositories", {"total_count": 1, "repositories": [{"full_name": R}]})
    w.r("POST", "graphql", {"data": {"revertPullRequest": {"revertPullRequest": {"number": 12, "url": "https://x/pull/12"}}}})
    return w


def revert(w, env=None):
    return H.run_script(RM, ["--repo", R, "--pr", "4", "--sha", F, "--app-slug", H.APP, "--run-url", "https://x/run/9"], w,
                        dict(APP_ENV, **(env or {})))


res = revert(world())
gql = [c for c in H.writes(res, "POST") if c["path"] == "graphql"]
S.check("opens the revert through revertPullRequest with the App token", res["rc"] == 0 and len(gql) == 1 and
        gql[0]["token"] == "ghs_ap" and "revertPullRequest" in gql[0]["input"]["query"], (res["rc"], res["err"]))
v = gql[0]["input"]["variables"] if gql else {}
S.check("title is a Conventional Commit revert of #4", v.get("title") == "revert: docs: x (#4)", v.get("title"))
S.check("body carries the revert-of marker", ("<!-- revert-of: #4 sha: %s -->" % F) in v.get("body", ""))
lab = [c for c in H.writes(res, "POST") if c["path"].endswith("/issues/12/labels")]
S.check("labels with the App token (so `labeled` re-runs the label checks): revert-on-red, the original class, semver:none",
        lab and lab[0]["token"] == "ghs_ap" and lab[0]["input"] == {"labels": ["revert-on-red", "riesgo:0", "semver:none"]}, lab)
S.check("the author of #4 is told", any(c["path"].endswith("/issues/4/comments") for c in H.writes(res, "POST")))
S.check("output revert_number", res["outputs"].get("revert_number") == "12", res["outputs"])

for label, kw, rc in (("not merged as that commit", {"sha": H.sha(5)}, 1),
                      ("merged by a person", {"merged_by": "igonzalezespi"}, 1),
                      ("a merge commit", {"parents": 2}, 1),
                      ("riesgo-3 trailer", {"trailer": 3}, 1),
                      ("no trailer", {"trailer": None}, 1)):
    res = revert(world(**kw))
    S.check("refuses: %s" % label, res["rc"] == rc and not any(c["path"] == "graphql" for c in res["calls"]), (res["rc"], res["err"]))
ex = {"number": 30, "user": {"login": APP_BOT}, "body": "<!-- revert-of: #4 sha: %s -->" % F}
res = revert(world(existing=[ex]))
S.check("idempotent: an existing revert of #4 is reused", res["rc"] == 0 and not any(c["path"] == "graphql" for c in res["calls"]))
res = revert(world(existing=[dict(ex, user={"login": "stranger"})]))
S.check("a forged marker by someone else is ignored", res["rc"] == 0 and any(c["path"] == "graphql" for c in res["calls"]))
res = revert(world(), {"GITHUB_ACTIONS": ""})
S.check("refuses outside GitHub Actions", res["rc"] == 2 and not any(c["path"] == "graphql" for c in res["calls"]))
res = revert(world(), {"MWG_WRITE_TOKEN": "gho_personal"})
S.check("refuses a personal token", res["rc"] == 2)
w = world(); w.r("POST", "graphql", {"errors": [{"message": "conflict"}]})
res = revert(w)
S.check("a GraphQL error is exit 1 (develop-health escalates)", res["rc"] == 1, res)
sys.exit(S.done())
