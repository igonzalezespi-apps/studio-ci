"""Shared helpers for risk-class, merge-when-green, develop-health and revert-merge.

Standard library only: these scripts run on a bare GitHub-hosted runner (or in a session) with
`python3` and the GitHub CLI, nothing else. A private repo runs them on its own runners, whose `gh`
can be as old as 2.45.0 (the Ubuntu 24.04 package): no flag newer than that.

Every GitHub call goes through `GH`, which shells out to `gh api` (the binary is `$GH`, `gh` by
default, so the test suites put a fake one first in PATH). Untrusted strings — titles, branch
names, bodies, labels — never reach a shell: arguments are passed as a list and request bodies
travel as JSON files (`--input`).
"""
import base64
import datetime as _dt
import json
import os
import re
import subprocess
import tempfile
from urllib.parse import quote

DEFAULT_IMPORTANT = (
    "secur|vulnerab|audit|gitleaks|secret|codeql|private-ref|install-vector|self-?hosted|guard|"
    "trivy|semgrep|sast|dependency-review|osv|scorecard|zizmor|sbom"
)
POLICY_PATH = "scripts/hooks/guard.policy.json"
CONFIG_PATH = ".github/merge-when-green.json"
FLOOR_LONG_LIVED = ("main", "master", "develop", "development", "trunk")
QUOTA_FLOOR = 300


class UsageError(Exception):
    """Bad invocation: exit 2."""


class ApiError(Exception):
    def __init__(self, status, message, path=""):
        super().__init__("%s (HTTP %s) %s" % (message, status, path))
        self.status = status
        self.path = path


class QuotaLow(Exception):
    """Fewer than QUOTA_FLOOR requests left: stop and decide `wait`."""


# ── time ────────────────────────────────────────────────────────────────────────────────────────
def now():
    fixed = os.environ.get("MWG_NOW")
    if fixed:
        return parse_time(fixed)
    return _dt.datetime.now(_dt.timezone.utc)


def parse_time(s):
    if not s:
        return None
    return _dt.datetime.strptime(s.replace("Z", "+0000"), "%Y-%m-%dT%H:%M:%S%z")


def iso(t):
    return t.strftime("%Y-%m-%dT%H:%M:%SZ") if t else ""


# ── globs (same semantics as core-dev reserved-surface.sh: `**` crosses `/`, `*` does not) ───────
_GLOB_CACHE = {}


def glob_to_regex(g):
    if g in _GLOB_CACHE:
        return _GLOB_CACHE[g]
    out, i = "", 0
    while i < len(g):
        c = g[i]
        if c == "*":
            if g[i:i + 3] == "**/":
                out += "(.*/)?"
                i += 3
                continue
            if g[i:i + 2] == "**":
                out += ".*"
                i += 2
                continue
            out += "[^/]*"
        elif c == "?":
            out += "[^/]"
        elif c in ".+()[]{}^$|\\":
            out += "\\" + c
        else:
            out += c
        i += 1
    rx = re.compile("^" + out + "$")
    _GLOB_CACHE[g] = rx
    return rx


def glob_match(path, glob):
    return bool(glob_to_regex(glob).match(path or ""))


def any_glob(path, globs):
    return any(glob_match(path, g) for g in globs)


# ── gh ──────────────────────────────────────────────────────────────────────────────────────────
def _parse_include(out):
    """Split `gh api -i` output into (status, headers, body-text)."""
    text = out.replace("\r\n", "\n")
    head, _, body = text.partition("\n\n")
    lines = head.split("\n")
    m = re.match(r"HTTP/\S+\s+(\d{3})", lines[0] if lines else "")
    status = int(m.group(1)) if m else 0
    headers = {}
    for ln in lines[1:]:
        k, _, v = ln.partition(":")
        headers[k.strip().lower()] = v.strip()
    return status, headers, body


def _status_from_stderr(err):
    m = re.search(r"\(HTTP (\d{3})\)", err or "")
    return int(m.group(1)) if m else 0


def json_values(text):
    """Every JSON value in `text`, in order: what `gh api --paginate` prints without `--slurp`."""
    dec = json.JSONDecoder()
    out, i, n = [], 0, len(text)
    while True:
        while i < n and text[i].isspace():
            i += 1
        if i >= n:
            return out
        value, i = dec.raw_decode(text, i)
        out.append(value)


class GH:
    """`gh api` with a call counter, a quota check and no shell."""

    def __init__(self, token=None, label="read"):
        self.token = token
        self.label = label
        self.calls = 0
        self.bin = os.environ.get("GH", "gh")
        self.quota_checked_at = -1
        self.quota_floor = int(os.environ.get("MWG_QUOTA_FLOOR", QUOTA_FLOOR))
        self.max_calls = int(os.environ.get("MWG_MAX_CALLS", "0") or 0)

    def _env(self):
        env = dict(os.environ)
        if self.token:
            env["GH_TOKEN"] = self.token
            env.pop("GITHUB_TOKEN", None)
        env.setdefault("GH_PROMPT_DISABLED", "1")
        env["NO_COLOR"] = "1"
        return env

    def _run(self, args, stdin_file=None, count=True):
        if count:
            self.calls += 1
            if self.max_calls and self.calls > self.max_calls:
                raise ApiError(0, "call budget exceeded (%d)" % self.max_calls)
        return self._exec(args)

    def _exec(self, args):
        try:
            p = subprocess.run([self.bin, "api"] + args, capture_output=True, text=True,
                               env=self._env(), timeout=120)
        except (OSError, subprocess.TimeoutExpired) as e:
            raise ApiError(0, "gh failed: %s" % e)
        return p

    def check_quota(self):
        """GET /rate_limit does not count against the quota. Raises QuotaLow under the floor."""
        p = self._run(["rate_limit"], count=False)
        if p.returncode != 0:
            return None
        try:
            remaining = json.loads(p.stdout)["resources"]["core"]["remaining"]
        except (ValueError, KeyError, TypeError):
            return None
        if remaining < self.quota_floor:
            raise QuotaLow("%d requests left (< %d)" % (remaining, self.quota_floor))
        return remaining

    def get(self, path):
        p = self._run(["-i", path])
        status, _, body = _parse_include(p.stdout)
        if p.returncode != 0 or status >= 400 or status == 0:
            status = status or _status_from_stderr(p.stderr)
            raise ApiError(status, (p.stderr or "").strip()[:200] or "request failed", path)
        try:
            return json.loads(body) if body.strip() else None
        except ValueError:
            raise ApiError(status, "not JSON", path)

    def get_or_none(self, path):
        try:
            return self.get(path)
        except ApiError as e:
            if e.status == 404:
                return None
            raise

    def list(self, path, key=None, max_pages=None, per_page=100):
        """All items of a list endpoint. `key` names the array inside an object page
        (`workflow_runs`, `jobs`, `check_runs`). `max_pages` stops early (newest first lists)."""
        sep = "&" if "?" in path else "?"
        if "per_page=" not in path:
            path = "%s%sper_page=%d" % (path, sep, per_page)
            sep = "&"
        if max_pages:
            items = []
            for page in range(1, max_pages + 1):
                data = self.get("%s%spage=%d" % (path, sep, page))
                chunk = (data or {}).get(key, []) if key else (data or [])
                if not isinstance(chunk, list):
                    raise ApiError(200, "unexpected page shape", path)
                items.extend(chunk)
                if len(chunk) < per_page:
                    break
            return items
        # No `--slurp`: it arrived in gh 2.48.0, and on gh 2.45.0 it is "unknown flag", so every list
        # call failed there. Without it `gh --paginate` writes one JSON value per page, back to
        # back (pages of an array endpoint come already merged into one array).
        p = self._run(["--paginate", path])
        if p.returncode != 0:
            raise ApiError(_status_from_stderr(p.stderr), (p.stderr or "").strip()[:200], path)
        try:
            pages = json_values(p.stdout or "")
        except ValueError:
            raise ApiError(200, "not JSON", path)
        items = []
        for page in pages:
            chunk = page.get(key) if (key and isinstance(page, dict)) else page
            if not isinstance(chunk, list):
                raise ApiError(200, "unexpected page shape", path)
            items.extend(chunk)
        return items

    def write(self, method, path, body=None):
        """(status, parsed-body). Never raises on an HTTP status: the caller decides."""
        args = ["-i", "--method", method, path]
        tmp = None
        if body is not None:
            fd, tmp = tempfile.mkstemp(prefix="mwg-", suffix=".json")
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                json.dump(body, fh)
            args += ["--input", tmp]
        try:
            p = self._run(args)
        finally:
            if tmp:
                os.unlink(tmp)
        status, _, text = _parse_include(p.stdout)
        status = status or _status_from_stderr(p.stderr)
        try:
            data = json.loads(text) if text.strip() else None
        except ValueError:
            data = None
        return status, data

    def graphql(self, query, variables):
        status, data = self.write("POST", "graphql", {"query": query, "variables": variables})
        if status != 200 or not isinstance(data, dict) or data.get("errors"):
            msg = json.dumps((data or {}).get("errors") or data)[:300]
            raise ApiError(status, "graphql: %s" % msg, "graphql")
        return data.get("data") or {}


# ── repo files: guard policy, merge-when-green config, workflows ─────────────────────────────────
def contents_path(repo, path, ref):
    """The contents API path for one file. The path and the ref are percent-encoded: `gh` cuts a
    raw `#` (and `?`) out of the URL, so `pkg/a#1/package.json` would ask for `pkg/a` instead and
    the caller would see "no such file" for a file that exists."""
    return "repos/%s/contents/%s?ref=%s" % (repo, quote(path, safe="/"), quote(ref, safe=""))


class RepoFiles:
    """Reads files of the integration branch: from a local sparse checkout (the reusable workflow
    makes one, at no API cost) or from the contents API (sessions, tests)."""

    def __init__(self, gh, repo, ref, directory=None):
        self.gh, self.repo, self.ref, self.dir = gh, repo, ref, directory

    def read(self, path):
        if self.dir:
            full = os.path.join(self.dir, path)
            if not os.path.isfile(full):
                return None
            with open(full, encoding="utf-8") as fh:
                return fh.read()
        data = self.gh.get_or_none(contents_path(self.repo, path, self.ref))
        if data is None:
            return None
        if not isinstance(data, dict) or "content" not in data:
            raise ApiError(200, "not a file", path)
        return base64.b64decode(data["content"]).decode("utf-8")

    def list_dir(self, path):
        if self.dir:
            full = os.path.join(self.dir, path)
            if not os.path.isdir(full):
                return []
            return sorted(os.path.join(path, n) for n in os.listdir(full))
        data = self.gh.get_or_none(contents_path(self.repo, path, self.ref))
        if not data:
            return []
        return sorted(e["path"] for e in data if e.get("type") == "file")


def load_json_text(text, what):
    if text is None:
        return None
    try:
        data = json.loads(text)
    except ValueError as e:
        raise UsageError("%s is not valid JSON: %s" % (what, e))
    if not isinstance(data, dict):
        raise UsageError("%s must be a JSON object" % what)
    return data


# ── the config file (.github/merge-when-green.json) ──────────────────────────────────────────────
# Mirrors config.schema.json; the suite checks that both declare the same keys.
CONFIG_KEYS = {
    "$schema": str,
    "version": int,
    "max_auto_class": int,
    "required_checks": list,
    "required_push_checks": list,
    "state_workflows": list,
    "settle_seconds": int,
    "risk_paths": list,
    "bot_authors": list,
    "renovate_minor_class": int,
    "app_slug": str,
    "verdict_authors": list,
    "pr_score": dict,
    "max_reverts_per_day": int,
    "max_candidates": int,
}
CONFIG_DEFAULTS = {
    "max_auto_class": 0,
    "state_workflows": [],
    "settle_seconds": 120,
    "risk_paths": [],
    "bot_authors": ["renovate[bot]"],
    "renovate_minor_class": 3,
    "app_slug": "",
    "verdict_authors": [],
    "pr_score": {"total": 22, "axis_min": 4},
    "max_reverts_per_day": 1,
    "max_candidates": 5,
}


def validate_config(cfg):
    """Returns (config-with-defaults, [problems]). An empty problem list means valid."""
    problems = []
    if not isinstance(cfg, dict):
        return None, ["the config is not a JSON object"]
    for k, v in cfg.items():
        if k not in CONFIG_KEYS:
            problems.append("unknown key %r" % k)
        elif not isinstance(v, CONFIG_KEYS[k]) or (CONFIG_KEYS[k] is int and isinstance(v, bool)):
            problems.append("%r must be %s" % (k, CONFIG_KEYS[k].__name__))
    if cfg.get("version") != 1:
        problems.append("'version' must be 1")
    out = dict(CONFIG_DEFAULTS)
    out.update({k: v for k, v in cfg.items() if k in CONFIG_KEYS})
    if problems:
        return out, problems
    if not 0 <= out["max_auto_class"] <= 2:
        problems.append("'max_auto_class' must be 0..2 (riesgo-3/4 are never automatic)")
    if not 0 <= out["renovate_minor_class"] <= 4:
        problems.append("'renovate_minor_class' must be 0..4")
    for key in ("required_checks", "required_push_checks"):
        lst = out.get(key)
        if not lst:
            problems.append("%r must list at least one {workflow, job}" % key)
            continue
        for e in lst:
            if not (isinstance(e, dict) and set(e) <= {"workflow", "job"}
                    and isinstance(e.get("workflow"), str) and e["workflow"]
                    and isinstance(e.get("job"), str) and e["job"]):
                problems.append("%r entries must be {\"workflow\": \"x.yml\", \"job\": \"name\"}" % key)
                break
    for e in out["risk_paths"]:
        if not (isinstance(e, dict) and isinstance(e.get("glob"), str) and e["glob"]
                and isinstance(e.get("class"), int) and 0 <= e["class"] <= 4
                and set(e) <= {"glob", "class", "why"}):
            problems.append("'risk_paths' entries must be {\"glob\", \"class\": 0..4, \"why\"}")
            break
    for key in ("bot_authors", "verdict_authors", "state_workflows"):
        if not all(isinstance(x, str) and x for x in out[key]):
            problems.append("%r must be a list of non-empty strings" % key)
    if out["max_auto_class"] >= 1 and not out["verdict_authors"]:
        problems.append("'max_auto_class' >= 1 needs 'verdict_authors' (riesgo-1/2 need a lens verdict)")
    ps = out["pr_score"]
    if not (isinstance(ps.get("total"), int) and isinstance(ps.get("axis_min"), int)):
        problems.append("'pr_score' must be {\"total\": int, \"axis_min\": int}")
    if out["max_reverts_per_day"] < 0 or out["max_candidates"] < 1:
        problems.append("'max_reverts_per_day' >= 0 and 'max_candidates' >= 1")
    if out["settle_seconds"] < 0 or out["settle_seconds"] > 900:
        problems.append("'settle_seconds' must be 0..900")
    return out, problems


def load_policy(files):
    text = files.read(POLICY_PATH)
    pol = load_json_text(text, POLICY_PATH) if text is not None else None
    return pol


def long_lived(policy):
    names = set(FLOOR_LONG_LIVED)
    for k in ("protected_branch", "integration_branch"):
        if (policy or {}).get(k):
            names.add(policy[k])
    for b in (policy or {}).get("long_lived_branches") or []:
        if isinstance(b, str) and b:
            names.add(b)
    return names


def important_pattern(policy):
    pat = (policy or {}).get("important_checks")
    if pat is None:
        return DEFAULT_IMPORTANT
    if not isinstance(pat, str) or not pat:
        raise UsageError("important_checks in the guard policy must be a non-empty string (an ERE)")
    try:
        re.compile(pat, re.I)
    except re.error as e:
        raise UsageError("important_checks does not compile: %s" % e)
    return pat


# ── GitHub Actions plumbing ─────────────────────────────────────────────────────────────────────
def set_output(name, value):
    path = os.environ.get("GITHUB_OUTPUT")
    if not path:
        return
    value = "" if value is None else str(value)
    with open(path, "a", encoding="utf-8") as fh:
        if "\n" in value:
            delim = "MWG_EOF_%d" % os.getpid()
            fh.write("%s<<%s\n%s\n%s\n" % (name, delim, value, delim))
        else:
            fh.write("%s=%s\n" % (name, value))


def summary(text):
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(text.rstrip("\n") + "\n")


def repo_arg(value):
    if not value or not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", value):
        raise UsageError("--repo must be <owner>/<name>, got %r" % (value or ""))
    return value


def pr_arg(value):
    if not value or not re.fullmatch(r"[1-9][0-9]{0,6}", str(value)):
        raise UsageError("--pr must be a PR number, got %r" % (value or ""))
    return int(value)


def sha_arg(value):
    if not value or not re.fullmatch(r"[0-9a-f]{40}", value):
        raise UsageError("--sha must be a full 40-hex commit SHA, got %r" % (value or ""))
    return value


def parse_args(argv, spec):
    """Tiny argv parser that fails fast: a flag that needs a value and has none is a usage error
    (the `--repo` with no value that hung two shell gates until their timeout)."""
    out = {k: (False if v == "flag" else None) for k, v in spec.items()}
    pos = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a.startswith("--"):
            name, eq, val = a[2:].partition("=")
            key = name.replace("-", "_")
            if key not in spec:
                raise UsageError("unknown flag --%s" % name)
            if spec[key] == "flag":
                if eq:
                    raise UsageError("--%s takes no value" % name)
                out[key] = True
                i += 1
                continue
            if not eq:
                if i + 1 >= len(argv) or argv[i + 1].startswith("--"):
                    raise UsageError("--%s needs a value" % name)
                val = argv[i + 1]
                i += 1
            out[key] = val
            i += 1
        else:
            pos.append(a)
            i += 1
    return out, pos


def write_json(path, data):
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2, sort_keys=True)
        fh.write("\n")
