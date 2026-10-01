#!/usr/bin/env python3
"""risk_class.py — classify a pull request into riesgo-0..riesgo-4.

    0  no runtime effect (docs, added tests, templates)              no lens
    1  bounded behaviour (small code change, edited tests)            Sonnet-high review
    2  agent or consumer behaviour (contracts, prompts, configs,
       dependency manifests, big code changes)                        Opus-high owner-decision lens
    3  the owner's hard core (guard, hooks, CI, the merge gate,
       security, Renovate config, anything with a failed important
       check)                                                         owner (revision-humana)
    4  money, irreversible or release (promotion, data model,
       credentials, IaC, a human semver:major)                        owner, never automatic

The HIGHEST class of any rule wins. A file is judged by its new AND its previous name, so a rename
cannot carry a file out of its class. Per-repo `risk_paths` (config) and `reserved_paths(_hard)`
(guard policy) can only RAISE a class: the floor below is not configurable downwards. Labels can
only raise too: `semver:minor` lifts code to 2, but `semver:patch` on a large change does not lower
it (size and paths are an independent floor).

Modes:
  --facts <file>   classify an already collected facts document (tests, offline use)
  --pr N --repo R  collect from the GitHub API (pulls, files, commits, policy, config)
  --git --base B [--head H] --repo-dir D   collect from a local checkout (pr-body)

Exit 0 when measured (whatever the class) · 2 when it could not measure: the caller never merges
on a 2.
"""
import base64
import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "merge-when-green"))
import mwg  # noqa: E402

MAX_FILES = 3000
CODE_LINES = 200
REVIEW = {0: "none", 1: "sonnet-high", 2: "opus-high", 3: "owner", 4: "owner"}

LOCKFILES = ("pnpm-lock.yaml", "package-lock.json", "yarn.lock", "pubspec.lock", "Cargo.lock",
             "poetry.lock", "Gemfile.lock", "npm-shrinkwrap.json", "bun.lockb", "uv.lock")
DEP_MANIFESTS = ("package.json", ".nvmrc", ".node-version", ".tool-versions", "pubspec.yaml")
TEST_GLOBS = ("**/*.test.*", "**/*.spec.*", "**/*_test.*", "**/test_*.py", "**/__tests__/**",
              "**/tests/**", "**/test/**", "**/fixtures/**", "**/__snapshots__/**")
DOC_EXT = (".md", ".mdx", ".markdown", ".txt", ".rst", ".adoc", ".png", ".jpg", ".jpeg", ".gif",
           ".svg", ".webp")
ALLOWED_LOCK_HOSTS = ("registry.npmjs.org", "registry.yarnpkg.com", "pub.dev", "pub.dartlang.org",
                      "crates.io", "static.crates.io", "index.crates.io", "pypi.org",
                      "files.pythonhosted.org", "rubygems.org")

# (class, rule-id, globs, unless-globs, why). Evaluated from the highest class down; within a file
# the first hit decides that file's class.
RULES = [
    (4, "data-model", ["**/migrations/**", "**/*.sql", "**/schema.prisma"], [], "the data model"),
    (4, "credentials", ["**/*.pem", "**/*.key", "**/*.p12", "**/*.pfx", "**/.env", "**/.env.*"], [],
     "credential material"),
    (4, "iac", ["**/*.tf", "**/*.tfvars", "**/*.tfstate"], [], "infrastructure as code (spend)"),
    (3, "ci", [".github/workflows/**", ".github/actions/**", ".github/CODEOWNERS", "CODEOWNERS",
               "docs/CODEOWNERS"], [], "CI and ownership: credentials, minutes and what judges a PR"),
    (3, "merge-gate", ["**/risk-class/**", "**/merge-when-green/**", "**/develop-health/**",
                       "**/revert-merge/**", "**/check-pr-tldr/**", "**/ci-gate/**",
                       ".github/merge-when-green.json", "**/pr-score/scripts/**"], [],
     "the merge gate itself: a PR must not relax its own gate"),
    (3, "guard", ["**/guard.policy.json", "scripts/hooks/**", ".githooks/**", "bootstrap.sh",
                  "security/**", ".claude/settings.json", ".claude/settings.local.json",
                  ".claude/hooks/**", "plugins/*/scripts/hooks/**", "plugins/*/hooks/**",
                  "plugins/*/policy/**", "**/.vendor.lock", "drift.manifest.json"], [],
     "the guard, the hooks and their policy"),
    (3, "supply-chain", ["renovate.json", "renovate.json5", ".renovaterc", ".renovaterc.json",
                         ".github/renovate.json", ".github/renovate.json5", "**/.npmrc",
                         "**/.yarnrc", "**/.yarnrc.yml", "**/pnpm-workspace.yaml"], [],
     "where dependencies come from and how they install"),
    (3, "license", ["LICENSE", "LICENSE.*", "LICENSE-*", "COPYING"], [], "the licence"),
    (2, "contract", ["**/CLAUDE.md", "**/AGENTS.md", "openspec/specs/**", "openspec/project.md"], [],
     "a contract or an architectural spec"),
    (2, "infra", ["infra/**"], [], "infrastructure (spend: the lens decides)"),
    (2, "agent-cabling", [".claude/**", "plugins/*/skills/**", "plugins/*/agents/**",
                          "plugins/*/commands/**", "plugins/*/output-styles/**",
                          "plugins/*/.claude-plugin/**", "**/output-styles/**"], [],
     "how the agent behaves"),
    (2, "action-api", ["action.yml", "action.yaml", "**/action.yml", "**/action.yaml"], [],
     "a shared action's public interface"),
    (2, "toolchain", ["**/package.json", "**/.nvmrc", "**/.node-version", "**/.tool-versions",
                      "**/Dockerfile", "**/Dockerfile.*", "orca.yaml", "**/pubspec.yaml"], [],
     "the toolchain or the dependency surface"),
    (2, "test-config", ["**/tsconfig*.json", "**/vitest.config.*", "**/vitest.workspace.*",
                        "**/jest.config.*", "**/playwright.config.*", "**/eslint.config.*",
                        "**/.eslintrc*", "codecov.yml", ".codecov.yml", "**/sonar-project.properties",
                        "**/turbo.json"], [],
     "what the checks check: a looser config turns a red into a green"),
    (2, "repo-config", [".github/**"], [".github/PULL_REQUEST_TEMPLATE.md",
                                        ".github/pull_request_template.md",
                                        ".github/ISSUE_TEMPLATE/**"],
     "repository configuration"),
    (2, "runbook", ["docs/**/runbook*", "docs/runbook*"], [], "an operational runbook"),
]
TEMPLATE_GLOBS = [".github/PULL_REQUEST_TEMPLATE.md", ".github/pull_request_template.md",
                  ".github/ISSUE_TEMPLATE/**", ".gitignore", "**/.gitignore", ".gitattributes"]
DANGEROUS_PKG_KEYS = ("pnpm", "overrides", "resolutions", "workspaces", "bin")
LIFECYCLE_SCRIPTS = ("preinstall", "install", "postinstall", "prepare", "prepublish",
                     "prepublishOnly", "prepack", "postpack", "dependencies")
DEP_KEYS = ("dependencies", "devDependencies", "peerDependencies", "optionalDependencies")


def _basename(p):
    return (p or "").rsplit("/", 1)[-1]


def is_lockfile(p):
    return _basename(p) in LOCKFILES


def is_test(p):
    return mwg.any_glob(p, TEST_GLOBS)


def is_doc(p):
    if p.startswith("docs/"):
        return p.lower().endswith(DOC_EXT)
    return p.lower().endswith((".md", ".mdx", ".markdown"))


# ── Renovate (and other dependency bots) ──────────────────────────────────────────────────────────
def _ver_tuple(v):
    v = re.sub(r"^[\^~>=<v\s]+", "", (v or "").strip())
    nums = re.findall(r"\d+", v.split(" ")[0])
    return tuple(int(n) for n in nums[:3]) if nums else None


def body_has_major(body):
    """Renovate's update table: `old` → `new`. A bump of the major (or of the minor in 0.x)."""
    for a, b in re.findall(r"`([^`]+)`\s*(?:→|->)\s*`([^`]+)`", body or ""):
        ta, tb = _ver_tuple(a), _ver_tuple(b)
        if not ta or not tb:
            continue
        if tb[0] > ta[0]:
            return True
        if ta[0] == 0 and tb[0] == 0 and len(ta) > 1 and len(tb) > 1 and tb[1] > ta[1]:
            return True
    return False


def renovate_automerge(body):
    return bool(re.search(r"\*\*Automerge\*\*:\s*Enabled", body or ""))


def _version_like(v):
    """A plain version or range: no git/file/link/URL/workspace/alias-to-elsewhere source."""
    if not isinstance(v, str) or not v.strip():
        return False
    s = v.strip()
    if s.startswith("npm:"):
        rest = s[4:]
        if "@" not in rest[1:]:
            return False
        s = rest.rsplit("@", 1)[1]
    if re.search(r"[:/#]|file|link|git|http|workspace", s, re.I):
        return False
    return bool(re.fullmatch(r"[0-9A-Za-z.^~<>=*|+\- ]+", s)) and bool(re.search(r"\d", s))


def package_json_problems(base_text, head_text):
    """For a bot: only dependency versions (and packageManager) may change. Returns a list of
    reasons the exemption is refused; empty = dependency versions only."""
    if head_text is None:
        return ["package.json removed or unreadable"]
    try:
        base = json.loads(base_text) if base_text else {}
        head = json.loads(head_text)
    except ValueError:
        return ["package.json is not valid JSON"]
    if not isinstance(base, dict) or not isinstance(head, dict):
        return ["package.json is not an object"]
    strip = lambda d: {k: v for k, v in d.items() if k not in DEP_KEYS + ("packageManager",)}  # noqa: E731
    out = []
    if strip(base) != strip(head):
        changed = sorted(k for k in set(base) | set(head)
                         if k not in DEP_KEYS + ("packageManager",) and base.get(k) != head.get(k))
        out.append("package.json changes more than dependency versions (%s)" % ", ".join(changed))
    for k in DEP_KEYS:
        for name, ver in (head.get(k) or {}).items():
            if (base.get(k) or {}).get(name) != ver and not _version_like(ver):
                out.append("package.json %s.%s is not a plain version (%s)" % (k, name, ver))
    return out


def package_json_dangerous(base_text, head_text):
    """For anybody: fields that change where code comes from or what runs at install."""
    try:
        base = json.loads(base_text) if base_text else {}
        head = json.loads(head_text) if head_text else {}
    except ValueError:
        return ["package.json is not valid JSON"]
    if not isinstance(base, dict) or not isinstance(head, dict):
        return []
    out = [k for k in DANGEROUS_PKG_KEYS if base.get(k) != head.get(k)]
    bs, hs = base.get("scripts") or {}, head.get("scripts") or {}
    if isinstance(bs, dict) and isinstance(hs, dict):
        out += ["scripts.%s" % s for s in LIFECYCLE_SCRIPTS if bs.get(s) != hs.get(s)]
    return out


def lockfile_foreign_hosts(patch):
    hosts = set()
    for line in (patch or "").splitlines():
        if not line.startswith("+") or line.startswith("+++"):
            continue
        if re.search(r"\bgit\+|\bgithub:|\bgit@|\bgitlab:|\bbitbucket:|\bfile:|\blink:", line):
            hosts.add("non-registry source")
        for h in re.findall(r"[a-z][a-z0-9+.-]*://([^/\s'\"]+)", line):
            if h.lower() not in ALLOWED_LOCK_HOSTS:
                hosts.add(h.lower())
    return sorted(hosts)


PIN_LINE = re.compile(r"^[+-]\s*(-\s*)?(uses:\s*\S+(\s+#.*)?|#.*)?\s*$")


def pin_only(patch):
    """A workflow diff whose every changed line is a `uses:` pin or a comment."""
    if not patch:
        return False
    changed = [ln for ln in patch.splitlines() if ln[:1] in "+-" and not ln.startswith(("+++", "---"))]
    return bool(changed) and all(PIN_LINE.match(ln) for ln in changed)


def bot_check(facts, cfg):
    """(is_bot_pr, problems). A bot PR keeps its exemption only if every commit is the bot's."""
    bots = set(cfg.get("bot_authors") or [])
    author = facts.get("author") or ""
    if author not in bots:
        return False, []
    problems = []
    commits = facts.get("commits")
    if commits is None:
        problems.append("commits not read")
    else:
        for c in commits:
            a, cm, ver = c.get("author"), c.get("committer"), c.get("verified")
            if a not in bots or not (cm in bots or (cm == "web-flow" and ver)):
                problems.append("a commit by %s/%s is not the bot's" % (a or "?", cm or "?"))
                break
    return True, problems


# ── the classifier ───────────────────────────────────────────────────────────────────────────────
def classify(facts, policy, cfg):
    cfg = dict(mwg.CONFIG_DEFAULTS, **(cfg or {}))
    policy = policy or {}
    reasons = {}

    def hit(cls, rule, why, path=None):
        key = (cls, rule)
        r = reasons.setdefault(key, {"class": cls, "rule": rule, "why": why, "paths": []})
        if path and path not in r["paths"] and len(r["paths"]) < 20:
            r["paths"].append(path)

    files = facts.get("files") or []
    labels = set(facts.get("labels") or [])
    base, head = facts.get("base_ref") or "", facts.get("head_ref") or ""
    body = facts.get("body") or ""
    blobs = facts.get("blobs") or {}
    is_bot, bot_problems = bot_check(facts, cfg)
    bot_clean = is_bot and not bot_problems

    # branches
    # A PR into the protected branch is a release only where there IS an integration branch: in a
    # trunk repo (no integration branch, or the same one) a PR into main is the ordinary flow.
    integ = policy.get("integration_branch") or ""
    if policy.get("protected_branch") and base == policy["protected_branch"] and integ and integ != base:
        hit(4, "promotion", "a promotion into the protected branch: a release")
    if head in mwg.long_lived(policy):
        hit(3, "long-lived-head", "the head is a long-lived branch (%s)" % head)

    # labels (only raise)
    semver = sorted(x for x in labels if x.startswith("semver:"))
    major = "semver:major" in labels or (is_bot and (body_has_major(body) or "/major-" in head))
    if major:
        if is_bot:
            hit(3, "major-update", "a major dependency update")
        else:
            hit(4, "semver-major", "a breaking change (semver:major)")
    if "semver:minor" in labels and not is_bot:
        hit(2, "semver-minor", "a new feature (semver:minor)")

    # per-repo paths
    extra = []
    for e in policy.get("reserved_paths_hard") or []:
        if isinstance(e, dict) and e.get("glob"):
            extra.append((3, "reserved-hard", e["glob"], e.get("why") or "declared hard by this repo"))
    for e in cfg.get("risk_paths") or []:
        extra.append((int(e["class"]), "risk-path", e["glob"], e.get("why") or "declared by this repo"))
    for e in policy.get("reserved_paths") or []:
        if isinstance(e, dict) and e.get("glob"):
            extra.append((2, "reserved", e["glob"], e.get("why") or "declared by this repo"))

    code_lines = 0
    bot_dep_files = []
    for f in files:
        names = [n for n in (f.get("filename"), f.get("previous_filename")) if n]
        status = f.get("status") or "modified"
        lines = int(f.get("additions") or 0) + int(f.get("deletions") or 0)
        patch = f.get("patch")
        file_class = None
        for name in names:
            c = None
            for cls, rule, globs, unless, why in RULES:
                if mwg.any_glob(name, globs) and not mwg.any_glob(name, unless):
                    if rule == "ci" and name.startswith(".github/workflows/") and bot_clean \
                            and pin_only(patch):
                        if re.search(r"studio-ci/", patch or ""):
                            hit(3, "gate-pin", "a pin of the shared CI/merge machinery", name)
                            c = 3
                        else:
                            hit(1, "bot-pin-only", "a bot bumps action pins only (Renovate merges it)", name)
                            c = 1
                        break
                    if rule == "toolchain" and _basename(name) == "package.json":
                        blob = blobs.get(f.get("filename"))
                        if blob is None and status != "removed":
                            danger = ["(not inspected)"]
                        else:
                            danger = package_json_dangerous((blob or {}).get("base"), (blob or {}).get("head"))
                        if danger:
                            hit(3, "install-surface", "package.json changes %s" % ", ".join(danger), name)
                            c = 3
                            break
                    if bot_clean and rule == "toolchain" and _basename(name) in DEP_MANIFESTS:
                        bot_dep_files.append(f)
                        c = -1  # decided below, as a whole
                        break
                    hit(cls, rule, why, name)
                    c = cls
                    break
            if c is None:
                if is_lockfile(name):
                    if bot_clean:
                        bot_dep_files.append(f)
                        c = -1
                    else:
                        hit(2, "lockfile", "a lockfile edited by a person (the lockfile-injection vector)", name)
                        c = 2
                elif mwg.any_glob(name, TEMPLATE_GLOBS):
                    hit(0, "template", "a template or ignore file", name)
                    c = 0
                elif is_test(name):
                    if status == "added" or (status == "renamed" and lines == 0):
                        hit(0, "tests-added", "new tests", name)
                        c = 0
                    else:
                        hit(1, "tests-changed", "existing tests edited or removed (a red can turn green)", name)
                        c = 1
                elif name.startswith("openspec/changes/"):
                    hit(0, "change-proposal", "a change proposal (not yet a spec)", name)
                    c = 0
                elif is_doc(name):
                    hit(0, "docs", "documentation", name)
                    c = 0
                else:
                    c = 1
                    code_lines += lines if name == f.get("filename") else 0
                    hit(1, "code", "code", name)
            # repo-declared surfaces (risk_paths, reserved_paths*): they ADD a reason, so they can
            # only ever raise the class; the floor's reason for this file stays
            for cls, rule, g, why in extra:
                if mwg.glob_match(name, g):
                    hit(cls, rule, why, name)
            file_class = c if file_class is None else max(file_class, c)

    # a bot PR that only touches dependency manifests and lockfiles
    if bot_dep_files:
        refusal = list(bot_problems)
        for f in bot_dep_files:
            name = f.get("filename")
            if _basename(name) == "package.json":
                refusal += package_json_problems(blobs.get(name, {}).get("base"),
                                                 blobs.get(name, {}).get("head"))
            if is_lockfile(name):
                if f.get("patch") is None:
                    refusal.append("%s: the API gave no patch, the lockfile cannot be audited" % name)
                else:
                    hosts = lockfile_foreign_hosts(f.get("patch"))
                    if hosts:
                        refusal.append("%s adds sources outside the registry (%s)" % (name, ", ".join(hosts)))
        if refusal:
            for f in bot_dep_files:
                hit(2, "bot-refused", "bot exemption refused: %s" % "; ".join(sorted(set(refusal))[:3]),
                    f.get("filename"))
        else:
            cls = int(cfg.get("renovate_minor_class", 3))
            why = ("a dependency bot update; this repo routes it to class %d (renovate_minor_class)" % cls)
            for f in bot_dep_files:
                hit(cls, "bot-dependencies", why, f.get("filename"))
    elif is_bot and bot_problems:
        hit(2, "bot-refused", "bot exemption refused: %s" % "; ".join(bot_problems))

    if code_lines > CODE_LINES:
        hit(2, "big-change", "%d changed lines of code (> %d)" % (code_lines, CODE_LINES))

    if facts.get("min_class") is not None:
        hit(int(facts["min_class"]), "raised", facts.get("min_reason") or "raised by the caller")

    if not files and not reasons:
        hit(0, "empty", "no file changes")

    cls = max([r["class"] for r in reasons.values()] + [0])
    ordered = sorted(reasons.values(), key=lambda r: (-r["class"], r["rule"]))
    out = {
        "class": cls,
        "label": "riesgo:%d" % cls,
        "review": REVIEW[cls],
        "reasons": ordered,
        "files": len(files),
        "lines_code": code_lines,
        "bot": is_bot,
        "bot_exempt": bool(is_bot and bot_dep_files and not any(r["rule"] == "bot-refused" for r in ordered)),
        "semver": semver,
        "missing_semver": len(semver) != 1,
        "renovate_automerge": renovate_automerge(body) if is_bot else False,
        "touches_workflows": any((f.get("filename") or "").startswith(".github/workflows/") or
                                 (f.get("previous_filename") or "").startswith(".github/workflows/")
                                 for f in files),
    }
    return out


# ── collectors ───────────────────────────────────────────────────────────────────────────────────
def collect_api(gh, repo, pr, policy=None, cfg=None, pull=None):
    """Facts for one PR. `pull` may come from a list call already made (saves one request)."""
    if pull is None:
        pull = gh.get("repos/%s/pulls/%d" % (repo, pr))
    if not isinstance(pull, dict) or "base" not in pull:
        raise mwg.ApiError(200, "unexpected pull shape", "pulls/%d" % pr)
    if int(pull.get("changed_files") or 0) > MAX_FILES:
        raise mwg.UsageError("more than %d changed files: not measurable" % MAX_FILES)
    files = gh.list("repos/%s/pulls/%d/files" % (repo, pr))
    if len(files) > MAX_FILES:
        raise mwg.UsageError("more than %d changed files: not measurable" % MAX_FILES)
    facts = {
        "base_ref": pull["base"]["ref"],
        "head_ref": pull["head"]["ref"],
        "base_repo": (pull["base"].get("repo") or {}).get("full_name"),
        "head_repo": (pull["head"].get("repo") or {}).get("full_name"),
        "author": (pull.get("user") or {}).get("login"),
        "labels": [lb["name"] for lb in pull.get("labels") or []],
        "body": pull.get("body") or "",
        "files": [{k: f.get(k) for k in ("status", "filename", "previous_filename", "additions",
                                           "deletions", "patch")} for f in files],
        "blobs": {},
    }
    bots = set((cfg or {}).get("bot_authors") or mwg.CONFIG_DEFAULTS["bot_authors"])
    if facts["author"] in bots:
        commits = gh.list("repos/%s/pulls/%d/commits" % (repo, pr))
        facts["commits"] = [{"author": (c.get("author") or {}).get("login"),
                             "committer": (c.get("committer") or {}).get("login"),
                             "verified": ((c.get("commit") or {}).get("verification") or {}).get("verified")}
                            for c in commits]
    base_sha, head_sha = pull["base"]["sha"], pull["head"]["sha"]
    for f in facts["files"]:
        name = f["filename"]
        if _basename(name) == "package.json" and f["status"] != "removed" and len(facts["blobs"]) < 20:
            facts["blobs"][name] = {
                "base": _blob(gh, repo, f.get("previous_filename") or name, base_sha),
                "head": _blob(gh, repo, name, head_sha),
            }
    return facts, pull


def _blob(gh, repo, path, ref):
    data = gh.get_or_none("repos/%s/contents/%s?ref=%s" % (repo, path, ref))
    if not data or "content" not in data:
        return None
    return base64.b64decode(data["content"]).decode("utf-8", "replace")


def collect_git(repo_dir, base, head, labels, author, base_ref, head_ref):
    def git(*args):
        return subprocess.run(["git", "-C", repo_dir] + list(args), capture_output=True, text=True,
                              check=True).stdout

    def show(ref, path):
        try:
            return git("show", "%s:%s" % (ref, path))
        except subprocess.CalledProcessError:
            return None

    mb = git("merge-base", base, head).strip()
    files, blobs = [], {}
    for ln in git("diff", "-M", "--name-status", mb, head).splitlines():
        parts = ln.split("\t")
        st = parts[0]
        if st.startswith("R"):
            prev, name, status = parts[1], parts[2], "renamed"
        else:
            prev, name = None, parts[1]
            status = {"A": "added", "D": "removed"}.get(st[0], "modified")
        paths = [p for p in (prev, name) if p]
        adds = dels = 0
        for row in git("diff", "-M", "--numstat", mb, head, "--", *paths).splitlines():
            cols = row.split("\t")
            adds += int(cols[0]) if cols[0].isdigit() else 0
            dels += int(cols[1]) if cols[1].isdigit() else 0
        patch = git("diff", "-M", mb, head, "--", *paths)
        files.append({"status": status, "filename": name, "previous_filename": prev,
                      "additions": adds, "deletions": dels, "patch": patch})
        if _basename(name) == "package.json" and status != "removed":
            blobs[name] = {"base": show(mb, prev or name), "head": show(head, name)}
    return {"base_ref": base_ref, "head_ref": head_ref, "author": author, "labels": labels,
            "files": files, "blobs": blobs, "body": ""}


def render(out):
    lines = ["%s  %s (%s review) — %d file(s), %d line(s) of code"
             % (out["label"], {0: "no runtime effect", 1: "bounded behaviour", 2: "agent/consumer behaviour",
                               3: "owner's hard core", 4: "money, irreversible or release"}[out["class"]],
                out["review"], out["files"], out["lines_code"])]
    for r in out["reasons"]:
        paths = (": " + ", ".join(r["paths"][:5]) + (" …" if len(r["paths"]) > 5 else "")) if r["paths"] else ""
        lines.append("  %d %-16s %s%s" % (r["class"], r["rule"], r["why"], paths))
    if out["missing_semver"]:
        lines.append("  ! not exactly one semver:* label (%s): never merged automatically"
                     % (", ".join(out["semver"]) or "none"))
    return "\n".join(lines)


USAGE = """usage:
  risk-class.sh --pr N --repo <owner>/<name> [--config PATH] [--min N --min-reason TXT] [--json]
  risk-class.sh --facts FILE [--policy FILE] [--config-file FILE] [--json]
  risk-class.sh --git --base REF [--head REF] [--repo-dir DIR] [--labels a,b] [--author LOGIN]
                [--base-ref NAME] [--head-ref NAME] [--policy FILE] [--config-file FILE] [--json]"""


def main(argv):
    spec = {"pr": "v", "repo": "v", "config": "v", "min": "v", "min_reason": "v", "json": "flag",
            "facts": "v", "policy": "v", "config_file": "v", "git": "flag", "base": "v", "head": "v",
            "repo_dir": "v", "labels": "v", "author": "v", "base_ref": "v", "head_ref": "v",
            "help": "flag"}
    try:
        a, pos = mwg.parse_args(argv, spec)
        if a["help"]:
            print(__doc__ + "\n" + USAGE)
            return 0
        if pos:
            raise mwg.UsageError("unexpected argument %r" % pos[0])
        policy = cfg = None
        if a["policy"]:
            policy = mwg.load_json_text(open(a["policy"], encoding="utf-8").read(), a["policy"])
        if a["config_file"]:
            cfg, problems = mwg.validate_config(
                mwg.load_json_text(open(a["config_file"], encoding="utf-8").read(), a["config_file"]))
            if problems:
                raise mwg.UsageError("config: " + "; ".join(problems))
        if a["facts"]:
            facts = json.load(open(a["facts"], encoding="utf-8"))
            policy = facts.pop("policy", policy)
            cfg = facts.pop("config", cfg)
        elif a["git"]:
            if not a["base"]:
                raise mwg.UsageError("--git needs --base")
            facts = collect_git(a["repo_dir"] or ".", a["base"], a["head"] or "HEAD",
                                [x for x in (a["labels"] or "").split(",") if x], a["author"] or "",
                                a["base_ref"] or "", a["head_ref"] or "")
        else:
            repo = mwg.repo_arg(a["repo"])
            pr = mwg.pr_arg(a["pr"])
            gh = mwg.GH(os.environ.get("MWG_READ_TOKEN") or None)
            pull = gh.get("repos/%s/pulls/%d" % (repo, pr))
            meta = gh.get("repos/%s" % repo)
            files = mwg.RepoFiles(gh, repo, meta["default_branch"])
            if policy is None:
                policy = mwg.load_policy(files) or {}
            if cfg is None:
                raw = files.read(a["config"] or mwg.CONFIG_PATH)
                if raw is not None:
                    cfg, problems = mwg.validate_config(mwg.load_json_text(raw, "config"))
                    if problems:
                        raise mwg.UsageError("config: " + "; ".join(problems))
            facts, _ = collect_api(gh, repo, pr, policy, cfg, pull=pull)
        if a["min"] is not None:
            if not re.fullmatch(r"[0-4]", a["min"]):
                raise mwg.UsageError("--min must be 0..4")
            facts["min_class"] = int(a["min"])
            facts["min_reason"] = a["min_reason"] or "raised by the caller"
        out = classify(facts, policy or {}, cfg or {})
    except mwg.UsageError as e:
        print("risk-class: %s" % e, file=sys.stderr)
        return 2
    except mwg.ApiError as e:
        print("risk-class: could not measure: %s" % e, file=sys.stderr)
        return 2
    except (OSError, ValueError, KeyError, TypeError) as e:
        print("risk-class: could not measure: %s: %s" % (type(e).__name__, e), file=sys.stderr)
        return 2
    print(json.dumps(out, sort_keys=True) if a["json"] else render(out))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
