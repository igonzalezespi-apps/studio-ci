#!/usr/bin/env bash
# Self-test of the two reusable workflows of autonomous merging: merge-when-green.yml and
# develop-health.yml.
#
# WHY. These files hold the security of the whole scheme, and none of it is visible to the unit
# suites of the scripts: which job may see the App key, that the key only exists in a job bound to
# an Environment, that no `${{ }}` reaches a shell, that the code is the pinned commit's and never
# the pull request's, that nothing cancels, that a private repo or a non-default ref never runs
# live. This suite reads the YAML for the static rules and EXTRACTS the real `run:` bodies to
# execute them with GitHub's shell (`bash --noprofile --norc -e -o pipefail`) across the scenarios,
# against a fake `gh` and a fake pr-merge.sh. Then it mutates the files and requires a failure.
#
# Usage: bash .github/workflows/merge-autonomo.test.sh
set -uo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

cat > "$TMP/check.py" <<'PY'
import json, os, re, subprocess, sys, tempfile
import yaml

SHELL = ["bash", "--noprofile", "--norc", "-e", "-o", "pipefail"]
fails = []


def fail(msg):
    fails.append(msg)


def load(path):
    text = open(path, encoding="utf-8").read()
    return text, yaml.safe_load(text)


def steps_of(job):
    return job.get("steps") or []


def step(job, name_part):
    for s in steps_of(job):
        if name_part in (s.get("name") or "") or name_part == s.get("id"):
            return s
    raise KeyError(name_part)


def run_body(body, env, cwd=None, path_prefix=None):
    with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as fh:
        fh.write(body)
        script = fh.name
    out_file = tempfile.mktemp()
    open(out_file, "w").close()
    e = {"PATH": (path_prefix + os.pathsep if path_prefix else "") + os.environ["PATH"], "GITHUB_OUTPUT": out_file,
         "RUNNER_TEMP": tempfile.gettempdir(), "HOME": os.environ.get("HOME", "/tmp")}
    e.update({k: str(v) for k, v in env.items()})
    p = subprocess.run(SHELL + [script], env=e, capture_output=True, text=True, cwd=cwd, timeout=60)
    outs = dict(ln.split("=", 1) for ln in open(out_file).read().splitlines() if "=" in ln)
    os.unlink(script); os.unlink(out_file)
    return p.returncode, outs, p.stdout + p.stderr


def static_rules(name, text, doc):
    on = doc.get("on", doc.get(True))
    if list((on or {}).keys()) != ["workflow_call"]:
        fail("%s: `on` must be only workflow_call" % name)
    if re.search(r"^\s*pull_request_target\s*:", text, re.M):
        fail("%s: pull_request_target as a trigger" % name)
    for line in text.splitlines():
        m = re.match(r"^\s*(?:-\s*)?uses:\s*([^\s#]+)(\s*#\s*(\S+))?", line)
        if m and not m.group(1).startswith("./"):
            ref = m.group(1).rsplit("@", 1)
            if len(ref) != 2 or not re.fullmatch(r"[0-9a-f]{40}", ref[1]) or not (m.group(3) or "").startswith("v"):
                fail("%s: action not pinned by SHA with its tag: %s" % (name, line.strip()))
    for jid, job in doc["jobs"].items():
        perms = job.get("permissions")
        if not isinstance(perms, dict):
            fail("%s/%s: no explicit job permissions" % (name, jid))
            perms = {}
        conc = job.get("concurrency") or {}
        if conc.get("cancel-in-progress") is not False:
            fail("%s/%s: concurrency must never cancel" % (name, jid))
        if "github.repository" not in str(conc.get("group", "")):
            fail("%s/%s: concurrency group is not per repository" % (name, jid))
        uses_key = "MERGE_APP_PRIVATE_KEY" in json.dumps(job)
        if uses_key and not job.get("environment"):
            fail("%s/%s: reads the App key without an Environment" % (name, jid))
        if "secrets." in json.dumps(job) and not job.get("environment"):
            fail("%s/%s: a job without an Environment reads secrets" % (name, jid))
        if uses_key:
            for bad in ("actions", "workflows", "administration", "packages"):
                if perms.get(bad) not in (None, "read") and bad != "actions":
                    fail("%s/%s: the App job asks for %s" % (name, jid, bad))
            if perms.get("actions") == "write":
                fail("%s/%s: the App job asks for actions: write" % (name, jid))
        for s in steps_of(job):
            body = s.get("run")
            if body and "${{" in body:
                fail("%s/%s: `${{` inside a run: (%s) — pass it through env:" % (name, jid, s.get("name")))
            u = s.get("uses") or ""
            w = s.get("with") or {}
            if u.startswith("actions/checkout@"):
                if w.get("persist-credentials") is not False:
                    fail("%s/%s: checkout without persist-credentials: false" % (name, jid))
                ref = str(w.get("ref", ""))
                if "pull_request" in ref or "head" in ref:
                    fail("%s/%s: checks out the pull request's code" % (name, jid))
                if w.get("path") == ".studio-ci" and (w.get("ref") != "${{ job.workflow_sha }}"
                                                     or w.get("repository") != "${{ job.workflow_repository }}"):
                    fail("%s/%s: the code is not the pinned commit (job.workflow_sha)" % (name, jid))
            if u.startswith("actions/create-github-app-token@"):
                if not job.get("environment"):
                    fail("%s/%s: mints the App token outside an Environment" % (name, jid))
                perm_keys = sorted(k for k in w if k.startswith("permission-"))
                if perm_keys != ["permission-contents", "permission-pull-requests"] or \
                        any(w[k] != "write" for k in perm_keys):
                    fail("%s/%s: App token permissions must be exactly contents+pull-requests write (%s)" % (name, jid, perm_keys))
                if "steps.gate.outputs.repo_name" not in str(w.get("repositories", "")):
                    fail("%s/%s: App token not scoped to this repository" % (name, jid))
                if str(w.get("skip-token-revoke")) != "true":
                    fail("%s/%s: skip-token-revoke must be 'true' (the step revokes it itself)" % (name, jid))
                if "!steps.app_token.outcome" not in str(w.get("private-key", "")):
                    fail("%s/%s: the key would reach the post step" % (name, jid))
                if "client-id" not in w or "app-id" in w:
                    fail("%s/%s: use client-id (app-id is deprecated in v3)" % (name, jid))
        for s in steps_of(job):
            if "MWG_WRITE_TOKEN" in json.dumps(s.get("env") or {}) and "trap revoke EXIT" not in (s.get("run") or ""):
                fail("%s/%s: the App token is not revoked by the step that uses it" % (name, jid))


def gate_cases(name, doc, job_id, cases):
    body = step(doc["jobs"][job_id], "gate")["run"]
    for label, env, want_rc, want in cases:
        rc, outs, log = run_body(body, env)
        ok = rc == want_rc and all(outs.get(k) == v for k, v in (want or {}).items())
        if not ok:
            fail("%s/%s gate: %s -> rc %s outs %s (want rc %s %s) %s" % (name, job_id, label, rc, outs, want_rc, want, log[-300:]))


BASE = {"EVENT_NAME": "workflow_run", "MODE": "live", "SELFTEST": "false", "PRIVATE": "false", "REPO": "acme/proyecto",
        "REF": "refs/heads/develop", "DEFAULT_BRANCH": "develop", "RUN_HEAD_REPO": "acme/proyecto",
        "WF_SHA": "a" * 40, "WF_REPO": "igonzalezespi-apps/studio-ci", "CLIENT_ID": "Iv23abc"}


def plan_gate_cases(name, doc, job_id, has_client=True):
    c = [
        ("live, public, default branch", {}, 0, {"live": "true", "mode": "live"}),
        # merge-when-green: no Environment in a private repo, so no live merging at all. develop-health:
        # its GITHUB_TOKEN side (re-run, freeze, escalate) may run live; its revert job refuses below.
        ("live in a private repo", {"PRIVATE": "true"}, 0,
         {"live": "false", "mode": "dry"} if has_client else {"live": "true"}),
        ("live on another ref runs dry", {"REF": "refs/heads/feat/x"}, 0, {"live": "false"}),
        ("live self-test runs dry", {"SELFTEST": "true"}, 0, {"live": "false"}),
        ("dry stays dry", {"MODE": "dry"}, 0, {"live": "false", "mode": "dry"}),
        ("pull_request outside the self-test", {"EVENT_NAME": "pull_request", "MODE": "dry"}, 1, None),
        ("pull_request self-test dry", {"EVENT_NAME": "pull_request", "MODE": "dry", "SELFTEST": "true"}, 0, {"live": "false"}),
        ("pull_request_target", {"EVENT_NAME": "pull_request_target"}, 1, None),
        ("an unknown event", {"EVENT_NAME": "issue_comment"}, 1, None),
        ("no job.workflow_sha", {"WF_SHA": ""}, 1, None),
        ("a bogus mode", {"MODE": "yes"}, 1, None),
    ]
    if has_client:
        c.append(("a workflow_run from a fork's branch is skipped", {"RUN_HEAD_REPO": "evil/fork"}, 0, {"skip": "true", "live": "false"}))
    else:
        c.append(("a workflow_run from a fork's branch is refused", {"RUN_HEAD_REPO": "evil/fork"}, 1, None))
    gate_cases(name, doc, job_id, [(l, dict(BASE, **e), rc, w) for l, e, rc, w in c])


APP_BASE = {"REF": "refs/heads/develop", "DEFAULT_BRANCH": "develop", "PRIVATE": "false", "REPO": "acme/proyecto",
            "WORKFLOW_REF": "acme/proyecto/.github/workflows/merge-when-green.yml@refs/heads/develop", "HAS_KEY": "true",
            "SELFTEST": "false", "CLIENT_ID": "Iv23abc"}


def app_gate_cases(name, doc, job_id):
    c = [
        ("all good", {}, 0, {"ok": "true", "repo_name": "proyecto"}),
        ("no key in the Environment", {"HAS_KEY": "false"}, 0, {"ok": "false"}),
        ("no client id in the Environment", {"CLIENT_ID": ""}, 0, {"ok": "false"}),
        ("private repo", {"PRIVATE": "true"}, 0, {"ok": "false"}),
        ("another ref", {"REF": "refs/heads/feat/x"}, 0, {"ok": "false"}),
        ("a workflow added on another branch", {"WORKFLOW_REF": "acme/proyecto/.github/workflows/x.yml@refs/heads/feat/x"}, 0, {"ok": "false"}),
        ("a workflow of another repository", {"WORKFLOW_REF": "evil/fork/.github/workflows/x.yml@refs/heads/develop"}, 0, {"ok": "false"}),
    ]
    if "SELFTEST" in json.dumps(step(doc["jobs"][job_id], "gate").get("env")):
        c.append(("self-test", {"SELFTEST": "true"}, 0, {"ok": "false"}))
    gate_cases(name, doc, job_id, [(l, dict(APP_BASE, **e), rc, w) for l, e, rc, w in c])


def fake_tools(tmp, rc_merge="0"):
    os.makedirs(os.path.join(tmp, "bin"), exist_ok=True)
    os.makedirs(os.path.join(tmp, ".studio-ci", "merge-when-green"), exist_ok=True)
    os.makedirs(os.path.join(tmp, ".studio-ci", "develop-health"), exist_ok=True)
    os.makedirs(os.path.join(tmp, ".studio-ci", "revert-merge"), exist_ok=True)
    log = os.path.join(tmp, "calls.log")
    open(log, "w").close()
    for rel in ("merge-when-green/pr-merge.sh", "develop-health/develop-health.sh", "revert-merge/revert-merge.sh"):
        with open(os.path.join(tmp, ".studio-ci", rel), "w") as fh:
            fh.write('#!/usr/bin/env bash\nprintf "%%s %%s\\n" "%s" "$*" >> "%s"\n'
                     'case "$1" in merge) exit "${RC_MERGE:-0}" ;; esac\nexit 0\n' % (rel, log))
    with open(os.path.join(tmp, "bin", "gh"), "w") as fh:
        fh.write('#!/usr/bin/env bash\nprintf "gh %%s token=%%s\\n" "$*" "${GH_TOKEN:0:6}" >> "%s"\nexit 0\n' % log)
    os.chmod(os.path.join(tmp, "bin", "gh"), 0o755)
    return log


def body_cases(name, doc):
    tmp = tempfile.mkdtemp()
    log = fake_tools(tmp)
    if name == "merge-when-green.yml":
        plan = step(doc["jobs"]["plan"], "Plan")["run"]
        env = {"REPO": "acme/proyecto", "EVENT_NAME": "workflow_run", "RUN_EVENT": "pull_request", "RUN_PRS": "[5, 6]", "PR": "", "MODE": "dry",
               "WRITE": "true", "SELFTEST": "false", "CONFIG_PATH": ".github/merge-when-green.json", "RUN_URL": "u",
               "VISIBILITY": "public"}
        for label, extra, want in (("workflow_run passes its PRs", {}, "--prs [5, 6]"),
                                   ("dispatch with a PR", {"EVENT_NAME": "workflow_dispatch", "PR": "7"}, "--pr 7"),
                                   ("self-test uses the built-in config and writes nothing",
                                    {"EVENT_NAME": "pull_request", "PR": "8", "SELFTEST": "true", "WRITE": "false"},
                                    "--comment false --labels false")):
            open(log, "w").close()
            rc, _, out = run_body(plan, dict(env, **extra), cwd=tmp)
            calls = open(log).read()
            if rc != 0 or want not in calls or (extra.get("SELFTEST") == "true" and "--selftest-config" not in calls):
                fail("%s plan body: %s (rc %s) %s %s" % (name, label, rc, calls, out[-200:]))
        for vis, want in (("public", "--max-settle-wait 150"), ("private", "--max-settle-wait 0")):
            open(log, "w").close()
            run_body(plan, dict(env, VISIBILITY=vis), cwd=tmp)
            if want not in open(log).read():
                fail("%s plan body: %s repo should pass %s" % (name, vis, want))
        open(log, "w").close()
        rc, _, out = run_body(plan, dict(env, RUN_EVENT="push", RUN_PRS="[]"), cwd=tmp)
        calls = open(log).read()
        if rc != 0 or "--prs" in calls or "--pr " in calls:
            fail("%s plan body: a push to develop must sweep every PR (%s)" % (name, calls))
        merge = step(doc["jobs"]["merge"], "Merge")["run"]
        menv = {"MWG_WRITE_TOKEN": "ghs_apptok", "REPO": "acme/proyecto", "PR": "5", "SHA": "b" * 40,
                "ESCALATE": "[9, 10]", "CONFIG_PATH": "c", "RUN_URL": "u"}
        for label, extra, want_rc in (("merged", {}, 0), ("re-decided: wait", {"RC_MERGE": "10"}, 0),
                                      ("re-decided: skip", {"RC_MERGE": "40"}, 0), ("usage error", {"RC_MERGE": "2"}, 1)):
            open(log, "w").close()
            rc, _, out = run_body(merge, dict(menv, **extra), cwd=tmp, path_prefix=os.path.join(tmp, "bin"))
            calls = open(log).read()
            if rc != want_rc:
                fail("%s merge body: %s -> rc %s (want %s) %s" % (name, label, rc, want_rc, out[-200:]))
            if "escalate --repo acme/proyecto --pr 9" not in calls or "--pr 10" not in calls:
                fail("%s merge body: escalations not run (%s)" % (name, calls))
            if "merge --repo acme/proyecto --pr 5 --sha " + "b" * 40 not in calls:
                fail("%s merge body: merge not pinned to the planned SHA (%s)" % (name, calls))
            if "gh api --method DELETE /installation/token --silent token=ghs_ap" not in calls:
                fail("%s merge body: the App token is not revoked (%s)" % (name, calls))
    else:
        rev = step(doc["jobs"]["revert"], "Open the revert")["run"]
        rc, _, out = run_body(rev, {"MWG_WRITE_TOKEN": "ghs_apptok", "APP_SLUG": "merge-app", "REPO": "acme/proyecto",
                                    "PR": "4", "SHA": "c" * 40, "RUN_URL": "u"}, cwd=tmp, path_prefix=os.path.join(tmp, "bin"))
        calls = open(log).read()
        if rc != 0 or "--app-slug merge-app" not in calls or "--sha " + "c" * 40 not in calls:
            fail("%s revert body: %s %s" % (name, calls, out[-200:]))
        if "DELETE /installation/token" not in calls:
            fail("%s revert body: token not revoked" % name)
        assess = step(doc["jobs"]["assess"], "Assess")["run"]
        open(log, "w").close()
        rc, _, out = run_body(assess, {"REPO": "acme/proyecto", "MODE": "dry", "CONFIG_PATH": "c", "RUN_URL": "u",
                                       "SELFTEST": "true"}, cwd=tmp)
        if rc != 0 or "--selftest-config" not in open(log).read():
            fail("%s assess body: self-test config not passed" % name)


def eval_if(expr, private, allow, runs_on):
    """The job-level `if:` that keeps a private repo off hosted runners, evaluated for real: the
    expression is translated to Python (only the operators it uses) and run per scenario."""
    py = re.sub(r"startsWith\(inputs\.runs-on, '([^']*)'\)", r"runs_on.startswith('\1')", expr)
    py = py.replace("github.event.repository.private", "private").replace("inputs.allow-hosted", "allow")
    py = py.replace("||", " or ").replace("&&", " and ")
    py = re.sub(r"!(?!=)", " not ", py)
    if re.search(r"[A-Za-z_.-]+\.[A-Za-z_-]+", py.replace("runs_on.startswith", "")):
        raise ValueError("unexpected context in the hosted-runner condition: %s" % expr)
    return bool(eval(py, {}, {"private": private, "allow": allow, "runs_on": runs_on}))


def hosted_cases(name, job_id, job):
    expr = str(job.get("if") or "")
    cases = (("public, hosted", False, False, "ubuntu-latest", True),
             ("private, hosted by default: never starts", True, False, "ubuntu-latest", False),
             ("private, another hosted image", True, False, "macos-14", False),
             ("private, opted in", True, True, "ubuntu-latest", True),
             ("private, own runner label", True, False, "self-hosted", True),
             ("private, own runner JSON list", True, False, '["self-hosted", "studio"]', True))
    for label, private, allow, runs_on, want in cases:
        try:
            got = eval_if(expr, private, allow, runs_on)
        except Exception as e:  # noqa: BLE001
            got = "error %s" % e
        if got is not want:
            fail("%s/%s hosted-runner guard: %s -> %s (want %s)" % (name, job_id, label, got, want))


def main(path):
    name = os.path.basename(path)
    text, doc = load(path)
    static_rules(name, text, doc)
    hosted_cases(name, "plan" if "plan" in doc["jobs"] else "assess", doc["jobs"].get("plan") or doc["jobs"]["assess"])
    for jid, job in doc["jobs"].items():
        for s in steps_of(job):
            w = s.get("with") or {}
            if w.get("path") == ".consumer" and "/.claude/settings.json" not in str(w.get("sparse-checkout", "")):
                fail("%s/%s: the caller's .claude/settings.json is not read (hook scripts would not be class 3)" % (name, jid))
    if name == "merge-when-green.yml":
        plan_gate_cases(name, doc, "plan")
        app_gate_cases(name, doc, "merge")
        if doc["jobs"]["plan"].get("environment"):
            fail("plan must not be bound to the Environment (it would hold the key)")
        cond = doc["jobs"]["merge"].get("if", "")
        if "needs.plan.outputs.live == 'true'" not in cond:
            fail("merge job not conditioned on live")
    else:
        plan_gate_cases(name, doc, "assess", has_client=False)
        app_gate_cases(name, doc, "revert")
        cond = doc["jobs"]["revert"].get("if", "")
        if "needs.assess.outputs.live == 'true'" not in cond or "revert" not in cond:
            fail("revert job not conditioned on live + action revert")
    body_cases(name, doc)
    for f in fails:
        print("    - " + f)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
PY

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
comprueba() { # <file> <label> <want-exit>
  local out rc=0
  out="$(python3 "$TMP/check.py" "$1" 2>&1)" || rc=$?
  if [ "$rc" -eq "$3" ]; then ok "$2"; else bad "$2 (exit $rc, want $3)"; printf '%s\n' "$out"; fi
}

echo "== the real files =="
comprueba "$HERE/merge-when-green.yml" "merge-when-green.yml: static rules, gates and bodies" 0
comprueba "$HERE/develop-health.yml" "develop-health.yml: static rules, gates and bodies" 0

echo "== mutants: each one MUST fail =="
mutate() { # <src> <label> <python transforming `text`>
  local dst
  dst="$TMP/$(basename "$1")"
  python3 - "$1" "$dst" "$3" <<'PY'
import sys
text = open(sys.argv[1]).read()
new = eval(sys.argv[3])
if new == text:
    sys.exit("mutant did not change the file")
open(sys.argv[2], "w").write(new)
PY
  if [ $? -ne 0 ]; then bad "$2 (mutant text no longer matches)"; return; fi
  comprueba "$dst" "mutant: $2" 1
}
MWG="$HERE/merge-when-green.yml"; DH="$HERE/develop-health.yml"
mutate "$MWG" "the merge job without an Environment" 'text.replace("    environment: ${{ inputs.environment }}\n", "", 1)'
mutate "$MWG" "a job that cancels" 'text.replace("cancel-in-progress: false", "cancel-in-progress: true", 1)'
mutate "$MWG" "an expression inside a run:" 'text.replace("args+=(--pr \"$PR\")", "args+=(--pr ${{ inputs.pr }})", 1)'
mutate "$MWG" "live in a private repo" 'text.replace("elif [ \"$PRIVATE\" != false ]; then", "elif false; then", 1)'
mutate "$MWG" "live on any ref" 'text.replace("elif [ \"$REF\" != \"refs/heads/$DEFAULT_BRANCH\" ]; then echo \"::warning::live only", "elif false; then echo \"::warning::live only", 1)'
mutate "$MWG" "the merge gate trusts any calling workflow" 'text.replace("\"$REPO/.github/workflows/\"*\"@refs/heads/$DEFAULT_BRANCH\") ;;", "*) ;;", 1)'
mutate "$MWG" "the code from the caller instead of the pinned commit" 'text.replace("ref: ${{ job.workflow_sha }}", "ref: ${{ github.sha }}", 1)'
mutate "$MWG" "checkout keeps credentials" 'text.replace("persist-credentials: false", "persist-credentials: true", 1)'
mutate "$MWG" "App token for every repo of the installation" 'text.replace("repositories: ${{ steps.gate.outputs.repo_name }}", "owner2: x", 1)'
mutate "$MWG" "App token with workflows permission" 'text.replace("permission-pull-requests: write\n", "permission-pull-requests: write\n          permission-workflows: write\n", 1)'
mutate "$MWG" "the key reaches the post step" 'text.replace("!steps.app_token.outcome && ", "", 1)'
mutate "$MWG" "no revoke" 'text.replace("trap revoke EXIT", "true", 1)'
mutate "$MWG" "a wait counts as a failure" 'text.replace("0 | 10 | 20 | 30 | 40) ;;", "0) ;;", 1)'
mutate "$MWG" "pull_request_target accepted" 'text.replace("pull_request_target) die", "pull_request_target) true", 1)'
mutate "$DH" "the revert job without an Environment" 'text.replace("    environment: ${{ inputs.environment }}\n", "", 1)'
mutate "$DH" "the revert on any ref" 'text.replace("[ \"$REF\" = \"refs/heads/$DEFAULT_BRANCH\" ] || { echo \"::warning::ref $REF is not the default branch\"; ok=false; }", "true", 1)'
mutate "$MWG" "a private repo runs the plan on a hosted runner" 'text.replace("!github.event.repository.private || inputs.allow-hosted ||", "true ||", 1)'
mutate "$DH" "a private repo runs assess on a hosted runner" 'text.replace("!github.event.repository.private || inputs.allow-hosted ||", "true ||", 1)'
mutate "$MWG" "the plan does not read the hook settings" 'text.replace("            /.claude/settings.json\n", "", 1)'
mutate "$DH" "the assess job reads the key" 'text.replace("          MWG_READ_TOKEN: ${{ github.token }}\n          REPO: ${{ github.repository }}\n          MODE:", "          MWG_READ_TOKEN: ${{ github.token }}\n          K: ${{ secrets.MERGE_APP_PRIVATE_KEY }}\n          REPO: ${{ github.repository }}\n          MODE:", 1)'

echo
echo "merge-autonomo.test.sh: $PASS ok, $FAIL failed"
[ "$FAIL" -eq 0 ]
