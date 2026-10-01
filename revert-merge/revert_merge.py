#!/usr/bin/env python3
"""revert_merge.py — open the revert of an automatic squash merge that turned the integration
branch red, with the merge App's token (a PR opened with GITHUB_TOKEN would never run its CI and
could never turn green).

    revert-merge.sh --repo R --pr N --sha F [--run-url U]

1. Re-checks that #N is merged as F, by the App, F has one parent and its `Risk-class:` trailer
   says riesgo:0..2.
2. Is idempotent: if the App already opened a revert of #N, prints it and stops.
3. GraphQL `revertPullRequest` (title `revert: <title> (#N)`, a `revert-of` marker in the body).
4. Labels it with the App token — `revert-on-red`, the ORIGINAL `riesgo:N` and `semver:none` — so
   the `labeled` event re-runs the label checks of the revert PR.
5. Comments on #N: the author re-opens it fixed.

merge-when-green merges the revert through its own path (same files as #N, CI green, opened by the
App, the original's class read from the commit trailer), exempt from the freeze it exists to lift.

Exit 0 opened (or already open) · 1 could not open it (develop-health escalates) · 2 usage.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "merge-when-green"))
sys.path.insert(0, os.path.join(HERE, "..", "risk-class"))
import mwg  # noqa: E402
import pr_merge  # noqa: E402

MUTATION = """mutation($id: ID!, $title: String!, $body: String!) {
  revertPullRequest(input: {pullRequestId: $id, title: $title, body: $body, draft: false}) {
    revertPullRequest { number url }
  }
}"""


def main(argv):
    spec = {"repo": "v", "pr": "v", "sha": "v", "run_url": "v", "app_slug": "v", "help": "flag"}
    try:
        a, pos = mwg.parse_args(argv, spec)
        if a["help"]:
            print(__doc__)
            return 0
        if pos:
            raise mwg.UsageError("unexpected argument %r" % pos[0])
        repo, pr, sha = mwg.repo_arg(a["repo"]), mwg.pr_arg(a["pr"]), mwg.sha_arg(a["sha"])
        if not a["app_slug"] or not re.fullmatch(r"[a-z0-9-]+", a["app_slug"]):
            raise mwg.UsageError("--app-slug must be the merge App's slug")
        app = pr_merge.bot_login(a["app_slug"])
        wgh = pr_merge.require_app_token(repo)
        gh = mwg.GH(os.environ.get("MWG_READ_TOKEN") or None)
        pull = gh.get("repos/%s/pulls/%d" % (repo, pr))
        if not pull.get("merged_at") or pull.get("merge_commit_sha") != sha:
            print("revert-merge: #%d is not merged as %s" % (pr, sha[:7]), file=sys.stderr)
            return 1
        if (pull.get("merged_by") or {}).get("login") != app:
            print("revert-merge: #%d was not merged by %s: never reverted automatically" % (pr, app), file=sys.stderr)
            return 1
        commit = gh.get("repos/%s/commits/%s" % (repo, sha))
        if len(commit.get("parents") or []) != 1:
            print("revert-merge: %s is not a single-parent squash" % sha[:7], file=sys.stderr)
            return 1
        t = pr_merge.TRAILER_RX.search((commit.get("commit") or {}).get("message") or "")
        if not t or int(t.group(1)) > 2:
            print("revert-merge: %s has no Risk-class riesgo:0..2 trailer" % sha[:7], file=sys.stderr)
            return 1
        cls = int(t.group(1))
        pulls = gh.list("repos/%s/pulls?state=all&sort=created&direction=desc" % repo, max_pages=1, per_page=50)
        for p in pulls:
            m = pr_merge.REVERT_MARK_RX.search(p.get("body") or "")
            if (p.get("user") or {}).get("login") == app and m and int(m.group(1)) == pr:
                print("revert-merge: #%d already reverted by #%d" % (pr, p["number"]))
                mwg.set_output("revert_number", p["number"])
                return 0
        orig_title = re.sub(r"\s*\(#\d+\)\s*$", "", pull.get("title") or "").strip()
        title = "revert: %s (#%d)" % (orig_title, pr)
        body = ("<!-- revert-of: #%d sha: %s -->\n"
                "Reverts #%d: after it was merged automatically, the required push checks of the integration "
                "branch went red and stayed red after a re-run.\n\n"
                "This is not an owner-risk change: it undoes an automatic merge (riesgo:%d). The author of #%d "
                "re-opens it fixed.\n\nRed run: %s\n" % (pr, sha, pr, cls, pr, a["run_url"] or "(local)"))
        data = wgh.graphql(MUTATION, {"id": pull["node_id"], "title": title, "body": body})
        rev = ((data.get("revertPullRequest") or {}).get("revertPullRequest") or {})
        num = rev.get("number")
        if not num:
            print("revert-merge: GitHub did not return the revert PR", file=sys.stderr)
            return 1
        st, _ = wgh.write("POST", "repos/%s/issues/%d/labels" % (repo, num),
                          {"labels": [pr_merge.REVERT_LABEL, "riesgo:%d" % cls, "semver:none"]})
        if st >= 300:
            print("revert-merge: opened #%d but could not label it (HTTP %s)" % (num, st), file=sys.stderr)
            return 1
        gh.write("POST", "repos/%s/issues/%d/comments" % (repo, pr),
                 {"body": "Revertida automáticamente en #%d: la rama de integración se puso en rojo tras el merge "
                          "y siguió en rojo tras relanzar. Reábrela corregida. Ejecución: %s"
                          % (num, a["run_url"] or "(local)")})
        mwg.set_output("revert_number", num)
        print("revert-merge: opened #%d (%s)" % (num, rev.get("url")))
        return 0
    except mwg.UsageError as e:
        print("revert-merge: %s" % e, file=sys.stderr)
        return 2
    except mwg.ApiError as e:
        print("revert-merge: %s" % e, file=sys.stderr)
        return 1
    except Exception as e:  # never half-open a revert silently
        print("revert-merge: could not open the revert (%s: %s)" % (type(e).__name__, e), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
