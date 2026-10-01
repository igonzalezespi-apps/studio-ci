"""Test harness shared by the risk-class, merge-when-green, develop-health and revert-merge suites.

A `World` is the GitHub a script will see: it compiles to the route table of the fake `gh` (next
to this file). `run()` executes a script against it and returns the exit code, the output and the
list of API calls, so a case can assert on what was ASKED and WRITTEN, not only on what was printed.

`SUT_ROOT` points the suites at another copy of the repo: that is how the mutation runners make
each suite prove it can fail.
"""
import base64
import json
import os
import subprocess
import tempfile
from urllib.parse import quote

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.environ.get("SUT_ROOT") or os.path.abspath(os.path.join(HERE, "..", ".."))
REPO = "acme/proyecto"
APP = "merge-app"
T0 = "2026-10-01T10:00:00Z"
NOW = "2026-10-01T12:00:00Z"


def sha(n):
    import hashlib
    return hashlib.sha1(("commit-%d" % n).encode()).hexdigest()


class World:
    def __init__(self, repo=REPO, private=False, default="develop"):
        self.repo = repo
        self.routes = {}
        self.remaining = 5000
        self._runs = {}
        self._branch_runs = {}
        self.r("GET", "repos/%s" % repo, {"full_name": repo, "default_branch": default, "private": private})
        self.default = default

    # low level
    def r(self, method, path, body=None, status=200):
        self.routes["%s %s" % (method, path)] = {"status": status, "body": body}

    def pages(self, path, pages):
        self.routes["GET %s" % path] = {"pages": pages}

    def seq(self, method, path, specs):
        self.routes["%s %s" % (method, path)] = {"seq": specs}

    # repo files (contents API)
    def file(self, path, text, ref=None):
        """A file of the repo, served by the contents API (percent-encoded like mwg.contents_path).
        `text=None` registers nothing (the path 404s)."""
        import hashlib
        ref = ref or self.default
        if text is None:
            return
        self.r("GET", "repos/%s/contents/%s?ref=%s" % (self.repo, quote(path, safe="/"), quote(ref, safe="")),
               {"type": "file", "path": path, "sha": hashlib.sha1(text.encode()).hexdigest(),
                "content": base64.b64encode(text.encode()).decode()})

    def workflows(self, files, ref=None):
        ref = ref or self.default
        self.r("GET", "repos/%s/contents/.github/workflows?ref=%s" % (self.repo, ref),
               [{"type": "file", "path": ".github/workflows/%s" % n} for n in sorted(files)])
        for n, text in files.items():
            self.file(".github/workflows/%s" % n, text, ref)

    def policy(self, **kw):
        pol = {"agent_may_merge": True, "protected_branch": "main", "integration_branch": "develop"}
        pol.update(kw)
        self.file("scripts/hooks/guard.policy.json", json.dumps(pol))
        return pol

    def config(self, **kw):
        cfg = {
            "version": 1,
            "max_auto_class": 0,
            "required_checks": [{"workflow": "ci.yml", "job": "test"}],
            "required_push_checks": [{"workflow": "ci.yml", "job": "test"}],
            "state_workflows": ["pr-tldr.yml"],
            "settle_seconds": 120,
            "app_slug": APP,
            "verdict_authors": ["owner"],
        }
        cfg.update(kw)
        cfg = {k: v for k, v in cfg.items() if v is not None}
        self.file(".github/merge-when-green.json", json.dumps(cfg))
        return cfg

    def eligible(self, **cfg):
        """A repo where automatic merging is allowed: policy, config, workflows, develop green."""
        self.policy()
        c = self.config(**cfg)
        self.workflows({"ci.yml": "name: CI\non: [pull_request, push]\n",
                        "develop-health.yml": "name: develop-health\n"})
        self.develop(sha(900), green=True)
        self.r("GET", "repos/%s/issues?state=open&labels=merge-freeze&per_page=100" % self.repo, [])
        return c

    def develop(self, head, green=True, conclusion=None, extra_runs=()):
        self.r("GET", "repos/%s/commits/develop" % self.repo,
               {"sha": head, "commit": {"committer": {"date": T0}}})
        runs = [run(800 + len(self._runs), "ci.yml", "push", "develop", head,
                    jobs=[job("test", conclusion or ("success" if green else "failure"))])] + list(extra_runs)
        self.runs(head, runs)

    # pulls
    def pull(self, n, title="feat: x", base="develop", head_ref=None, author="dev", labels=("semver:patch",),
             draft=False, body=None, fork=False, created=T0, mergeable=True, state="open", head_sha=None,
             merged_by=None, merge_commit_sha=None, merged_at=None):
        p = {
            "number": n, "node_id": "PR_node%d" % n, "title": title, "state": state, "draft": draft,
            "created_at": created, "user": {"login": author, "type": "Bot" if author.endswith("[bot]") else "User"},
            "labels": [{"name": x} for x in labels],
            "body": body if body is not None else "## Merge method\n\n- [x] Squash\n",
            "base": {"ref": base, "sha": sha(500 + n), "repo": {"full_name": self.repo}},
            "head": {"ref": head_ref or "feat/pr-%d" % n, "sha": head_sha or sha(n),
                     "repo": {"full_name": "someone/fork" if fork else self.repo}},
            "mergeable": mergeable, "mergeable_state": "clean" if mergeable else ("dirty" if mergeable is False else "unknown"),
            "merged_at": merged_at, "merged_by": {"login": merged_by} if merged_by else None,
            "merge_commit_sha": merge_commit_sha, "changed_files": 1,
        }
        self.r("GET", "repos/%s/pulls/%d" % (self.repo, n), p)
        return p

    def open_pulls(self, pulls):
        self.r("GET", "repos/%s/pulls?state=open&base=develop&sort=created&direction=asc&per_page=100" % self.repo,
               list(pulls))
        self.r("GET", "repos/%s/pulls?state=open&per_page=100" % self.repo, list(pulls))

    def files(self, n, files):
        out = []
        for f in files:
            if isinstance(f, str):
                f = {"filename": f}
            d = {"status": "modified", "additions": 5, "deletions": 1, "patch": "@@ -1 +1 @@\n-a\n+b"}
            d.update(f)
            out.append(d)
        self.pages("repos/%s/pulls/%d/files?per_page=100" % (self.repo, n), [out])
        return out

    def commits(self, n, commits=None):
        commits = commits or [{"author": "dev", "committer": "dev", "message": "feat: x\n\nbody of the change"}]
        out = [{"sha": sha(3000 + i), "author": {"login": c.get("author")}, "committer": {"login": c.get("committer")},
                "commit": {"message": c.get("message", "chore: x"), "verification": {"verified": c.get("verified", True)}}}
               for i, c in enumerate(commits)]
        self.pages("repos/%s/pulls/%d/commits?per_page=100" % (self.repo, n), [out])

    def comments(self, n, comments=()):
        self.pages("repos/%s/issues/%d/comments?per_page=100" % (self.repo, n), [list(comments)])

    # CI
    def runs(self, head_sha, runs):
        self._runs[head_sha] = list(runs)
        self.pages("repos/%s/actions/runs?head_sha=%s&per_page=100" % (self.repo, head_sha),
                   [{"workflow_runs": [strip(r) for r in runs]}])
        for r_ in runs:
            self.pages("repos/%s/actions/runs/%d/jobs?filter=all&per_page=100" % (self.repo, r_["id"]),
                       [{"jobs": r_["_jobs"]}])

    def checks(self, head_sha, check_runs=(), statuses=()):
        self.pages("repos/%s/commits/%s/check-runs?filter=all&per_page=100" % (self.repo, head_sha),
                   [{"check_runs": list(check_runs)}])
        self.r("GET", "repos/%s/commits/%s/status" % (self.repo, head_sha), {"state": "pending", "statuses": list(statuses)})

    def branch_history(self, branch, runs, extra=""):
        self.r("GET", "repos/%s/actions/runs?branch=%s%s&per_page=100&page=1" % (self.repo, branch.replace("/", "%2F"), extra),
               {"workflow_runs": [strip(r) for r in runs]})
        for r_ in runs:
            self.pages("repos/%s/actions/runs/%d/jobs?filter=all&per_page=100" % (self.repo, r_["id"]),
                       [{"jobs": r_["_jobs"]}])

    def green_pr(self, n, **kw):
        """A PR whose required CI is green and settled, with no important failure."""
        p = self.pull(n, **kw)
        s = p["head"]["sha"]
        self.runs(s, [run(1000 + n, "ci.yml", "pull_request", p["head"]["ref"], s, jobs=[job("test")])])
        self.checks(s)
        self.branch_history(p["head"]["ref"], [])
        self.comments(n)
        self.commits(n)
        self.events(n)
        return p

    def events(self, n, labelled=()):
        """The issue events of #n: one `labeled` event per name in `labelled`."""
        self.pages("repos/%s/issues/%d/events?per_page=100" % (self.repo, n),
                   [[{"event": "labeled", "label": {"name": x}} for x in labelled]])

    def save(self, path):
        with open(path, "w", encoding="utf-8") as fh:
            json.dump({"routes": self.routes, "remaining": self.remaining}, fh)


def strip(r):
    return {k: v for k, v in r.items() if k != "_jobs"}


_IDS = [100000]


def job(name, conclusion="success", status="completed", attempt=1, steps=None, started=None, completed=None,
        runner="GitHub Actions 7"):
    _IDS[0] += 1
    if steps is None:
        steps = [{"name": "Set up job", "status": "completed", "conclusion": "success"},
                 {"name": "Run", "status": "completed", "conclusion": conclusion if status == "completed" else None}]
    return {"id": _IDS[0], "name": name, "status": status,
            "conclusion": conclusion if status == "completed" else None, "run_attempt": attempt, "steps": steps,
            "started_at": started or "2026-10-01T11:00:00Z",
            "completed_at": (completed or "2026-10-01T11:05:00Z") if status == "completed" else None,
            "runner_name": runner}


def run(rid, wf, event, branch, head_sha, jobs, attempt=None, created=None, name=None, prs=None):
    # like GitHub: the run's status and conclusion are those of its LATEST attempt
    last = max([j["run_attempt"] for j in jobs] or [1])
    latest = [j for j in jobs if j["run_attempt"] == last]
    conclusion = "success"
    if any(j["status"] != "completed" for j in latest):
        conclusion = None
    elif any(j["conclusion"] not in ("success", "skipped", "neutral") for j in latest):
        conclusion = "failure"
    return {"id": rid, "name": name or wf.split(".")[0], "path": ".github/workflows/%s" % wf, "event": event,
            "head_branch": branch, "head_sha": head_sha, "status": "completed" if conclusion else "in_progress",
            "conclusion": conclusion, "run_attempt": attempt or max([j["run_attempt"] for j in jobs] or [1]),
            "created_at": created or "2026-10-01T11:00:00Z", "pull_requests": [{"number": n} for n in (prs or [])],
            "head_repository": {"full_name": REPO}, "_jobs": jobs}


# ── running a script: in-process by default (fast enough to run every mutant), or as a real
# subprocess through the bash wrapper and the fake `gh` binary (HARNESS_SUBPROCESS=1) ─────────────
MODULES = {
    "risk-class/risk-class.sh": "risk_class",
    "merge-when-green/ci-verdict.sh": "ci_verdict",
    "merge-when-green/pr-merge.sh": "pr_merge",
    "develop-health/develop-health.sh": "develop_health",
    "revert-merge/revert-merge.sh": "revert_merge",
}
_LOADED = {}


def _load():
    if _LOADED:
        return _LOADED
    import importlib
    import importlib.machinery
    import importlib.util
    import sys
    for d in ("merge-when-green", "risk-class", "develop-health", "revert-merge"):
        full = os.path.join(ROOT, d)
        if full not in sys.path:
            sys.path.insert(0, full)
    loader = importlib.machinery.SourceFileLoader("fakegh", os.path.join(HERE, "gh"))
    spec = importlib.util.spec_from_loader("fakegh", loader)
    fake = importlib.util.module_from_spec(spec)
    loader.exec_module(fake)
    import mwg
    from types import SimpleNamespace

    def _exec(self, args):
        import io
        from contextlib import redirect_stderr, redirect_stdout
        saved = os.environ.get("GH_TOKEN")
        os.environ["GH_TOKEN"] = self._env().get("GH_TOKEN", "")
        o, er = io.StringIO(), io.StringIO()
        try:
            with redirect_stdout(o), redirect_stderr(er):
                rc = fake.main(["api"] + list(args))
        finally:
            if saved is None:
                os.environ.pop("GH_TOKEN", None)
            else:
                os.environ["GH_TOKEN"] = saved
        return SimpleNamespace(returncode=rc, stdout=o.getvalue(), stderr=er.getvalue())

    mwg.GH._exec = _exec
    for rel, name in MODULES.items():
        _LOADED[rel] = importlib.import_module(name)
    return _LOADED


def _inproc(rel, args, e):
    import io
    from contextlib import redirect_stderr, redirect_stdout
    mod = _load()[rel]
    saved = dict(os.environ)
    os.environ.clear()
    os.environ.update(e)
    out, err = io.StringIO(), io.StringIO()
    try:
        with redirect_stdout(out), redirect_stderr(err):
            try:
                rc = mod.main(list(args))
            except SystemExit as x:
                rc = x.code if isinstance(x.code, int) else 1
    finally:
        os.environ.clear()
        os.environ.update(saved)
    return rc, out.getvalue(), err.getvalue()


def run_script(rel, args, world, env=None, input_files=None):
    tmp = tempfile.mkdtemp(prefix="mwg-test-")
    db, log = os.path.join(tmp, "db.json"), os.path.join(tmp, "log.jsonl")
    world.save(db)
    open(log, "w").close()
    e = dict(os.environ)
    e.update({"PATH": HERE + os.pathsep + e.get("PATH", ""), "FAKE_GH_DB": db, "FAKE_GH_LOG": log,
              "MWG_NOW": NOW, "MWG_FAKE_SLEEP": "1", "GH_TOKEN": "ghs_readtoken"})
    for k in ("GITHUB_ACTIONS", "MWG_WRITE_TOKEN", "MWG_WRITE_TOKEN_KIND", "GITHUB_OUTPUT", "GITHUB_STEP_SUMMARY",
              "MWG_READ_TOKEN"):
        e.pop(k, None)
    out_file = os.path.join(tmp, "out.txt")
    open(out_file, "w").close()
    e["GITHUB_OUTPUT"] = out_file
    e.update(env or {})
    if os.environ.get("HARNESS_SUBPROCESS") or rel not in MODULES:
        p = subprocess.run([os.path.join(ROOT, rel)] + list(args), capture_output=True, text=True, env=e, timeout=60)
        rc, stdout, stderr = p.returncode, p.stdout, p.stderr
    else:
        rc, stdout, stderr = _inproc(rel, args, e)
    calls = [json.loads(ln) for ln in open(log, encoding="utf-8") if ln.strip()]
    outputs = {}
    for ln in open(out_file, encoding="utf-8").read().splitlines():
        if "=" in ln and "<<" not in ln:
            k, _, v = ln.partition("=")
            outputs[k] = v
    import shutil
    shutil.rmtree(tmp, ignore_errors=True)
    return {"rc": rc, "out": stdout, "err": stderr, "calls": calls, "outputs": outputs}


class Suite:
    def __init__(self, name):
        self.name, self.passed, self.failed = name, 0, []

    def check(self, label, cond, detail=""):
        if cond:
            self.passed += 1
            if os.environ.get("VERBOSE"):
                print("  ok   %s" % label)
        else:
            self.failed.append(label)
            print("  FAIL %s %s" % (label, ("— " + str(detail)[:600]) if detail else ""))
            if os.environ.get("FAIL_FAST"):
                raise SystemExit(1)

    def done(self):
        total = self.passed + len(self.failed)
        print("%s: %d/%d cases pass" % (self.name, self.passed, total))
        return 0 if not self.failed else 1


def writes(res, method=None, path_part=""):
    return [c for c in res["calls"] if c["method"] != "GET" and (method is None or c["method"] == method)
            and path_part in (c["path"] or "")]
