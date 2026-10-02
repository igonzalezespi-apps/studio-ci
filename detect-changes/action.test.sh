#!/usr/bin/env bash
# action.test.sh — the wiring and the arithmetic of detect-changes/action.yml.
#
# `functional` is the output every consuming repo gates its test jobs on, and the failure that
# matters is the silent one: a PR that changes code, is classified as docs-only, skips the suite
# and reports green. So this suite:
#   1. reads the YAML for the wiring: both paths-filter calls are the same pinned action over the
#      same base, the second one counts every changed file, the last step reads its inputs from
#      `env:` (a file name never reaches a shell as code), and each bucket output has its filter;
#   2. EXTRACTS the real body of the "functional" step (not a copy) and runs it with GitHub's shell
#      (`bash --noprofile --norc -e -o pipefail`) over the cases;
#   3. mutates that body and requires a failing case for each mutant.
# Which bucket a real path falls in is paths-filter's glob dialect: that table runs for real in
# GitHub, in .github/workflows/detect-changes-selftest.yml.
#
# Usage: bash detect-changes/action.test.sh
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT INT TERM
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

cat > "$TMP/wiring.py" <<'PY'
import re, sys, yaml
fails = []
d = yaml.safe_load(open(sys.argv[1]))
steps = d["runs"]["steps"]
by_id = {s.get("id"): s for s in steps}

# 1. the two paths-filter calls: same pinned action, same base, the second one a catch-all
detect, count = by_id["filter"], by_id["all"]
if not detect["uses"].startswith("dorny/paths-filter@") or detect["uses"] != count["uses"]:
    fails.append("the two paths-filter calls differ: %s / %s" % (detect["uses"], count["uses"]))
for s in (detect, count):
    if s["with"].get("base") != "${{ inputs.base }}":
        fails.append("%s: not diffed against inputs.base" % s["id"])
if yaml.safe_load(count["with"]["filters"]) != {"changed": ["**"]}:
    fails.append("the counting call is not exactly one catch-all filter")
if set(count["with"]) - {"base", "filters"}:
    fails.append("the counting call has extra inputs: %s" % sorted(set(count["with"]) - {"base", "filters"}))

# 2. the functional step: inputs only through env, from the right outputs
fn = by_id["functional"]
if "${{" in fn["run"]:
    fails.append("an expression inside the functional step's run:")
want_env = {"CODE": "code", "DEPS": "deps", "CI": "ci", "E2E_RELEVANT": "e2e_relevant",
            "DB_MIGRATION": "db_migration", "I18N": "i18n", "ASSETS": "assets"}
env = fn.get("env") or {}
for k, b in want_env.items():
    if env.get(k) != "${{ steps.filter.outputs.%s }}" % b:
        fails.append("env %s does not read the %s bucket" % (k, b))
if env.get("DOCS_COUNT") != "${{ steps.filter.outputs.docs_count }}":
    fails.append("DOCS_COUNT does not read the docs bucket's count")
if env.get("CHANGED_COUNT") != "${{ steps.all.outputs.changed_count }}":
    fails.append("CHANGED_COUNT does not read the catch-all count")
open(sys.argv[3], "w").write(fn["run"])

# 3. the default filters: valid YAML, one filter per bucket output and one output per filter
body = by_id["defaults"]["run"]
m = re.search(r"<<'YML'\n(.*?)\nYML\n", body, re.S)
defaults = yaml.safe_load(m.group(1)) if m else None
if not isinstance(defaults, dict):
    fails.append("the default filters do not parse")
    defaults = {}
outputs = set(d["outputs"]) - {"functional"}
if set(defaults) != outputs:
    fails.append("buckets %s != bucket outputs %s" % (sorted(defaults), sorted(outputs)))
for k, v in d["outputs"].items():
    if k != "functional" and v["value"] != "${{ steps.filter.outputs.%s }}" % k:
        fails.append("output %s does not read its bucket" % k)
if set(want_env.values()) != set(defaults) - {"docs"}:
    fails.append("the functional step does not read every non-docs bucket: %s" % sorted(want_env.values()))

# 4. the default docs bucket keeps its criterion: documentation only, never what CI runs or reads
whole = [p for p in defaults.get("docs", []) if re.fullmatch(r"\.[^/*]+/\*\*", p)]
if whole:
    fails.append("docs takes a whole dot-folder, hooks, settings and scripts included: %s" % whole)
for p in ("**/test/**", "**/tests/**", "**/__tests__/**", "**/integration_test/**", "**/e2e/**",
          "**/fixtures/**", "**/__fixtures__/**", "**/testdata/**", "**/__snapshots__/**"):
    if p not in defaults.get("code", []):
        fails.append("code does not hold %s: a Markdown file a test reads there would be docs" % p)

# 5. the GitHub self-test runs this very directory, over a staged working tree
wf = yaml.safe_load(open(sys.argv[2]))
on = wf.get("on", wf.get(True))
paths = on["pull_request"]["paths"]
if "detect-changes/**" not in paths:
    fails.append("the self-test does not run when detect-changes changes")
job = wf["jobs"]["scenario"]
uses = [s for s in job["steps"] if s.get("uses") == "./detect-changes"]
if len(uses) != 1 or uses[0]["with"].get("base") != "HEAD":
    fails.append("the self-test does not call ./detect-changes with base: HEAD")
cases = job["strategy"]["matrix"]["include"]
if job["strategy"].get("fail-fast") is not False:
    fails.append("the self-test stops at the first failing scenario")
for c in cases:
    if c.get("functional") not in ("true", "false") or "name" not in c:
        fails.append("a self-test scenario without name or expected functional: %s" % c)
if not any(c["functional"] == "false" for c in cases) or not any(c["functional"] == "true" for c in cases):
    fails.append("the self-test does not expect both answers")
for f in fails:
    print("    - " + f)
sys.exit(1 if fails else 0)
PY
# wiring <action.yml>: also writes the functional step's body to $TMP/functional.sh
wiring() { python3 "$TMP/wiring.py" "$1" "$HERE/../.github/workflows/detect-changes-selftest.yml" "$TMP/functional.sh"; }

echo "== wiring =="
if out=$(wiring "$HERE/action.yml" 2>&1); then ok "action.yml and the GitHub self-test are wired as documented"
else bad "wiring"; printf '%s\n' "$out"; fi

# run_case <body> <label> <want-exit> <want-value|-> <env assignments...>
run_case() {
  local body=$1 label=$2 want_rc=$3 want=$4; shift 4
  : > "$TMP/out"
  local rc=0
  env -i PATH="$PATH" GITHUB_OUTPUT="$TMP/out" CODE= DEPS= CI= E2E_RELEVANT= DB_MIGRATION= I18N= ASSETS= \
    DOCS_COUNT= CHANGED_COUNT= "$@" bash --noprofile --norc -e -o pipefail "$body" > "$TMP/log" 2>&1 || rc=$?
  local got
  got=$(sed -n 's/^value=//p' "$TMP/out")
  if [ "$rc" -ne "$want_rc" ]; then echo "exit $rc, want $want_rc"; return 1; fi
  if [ "$want" = "-" ]; then
    [ -z "$got" ] || { echo "wrote value=$got on a failure"; return 1; }
  elif [ "$got" != "$want" ]; then echo "value='$got', want '$want'"; return 1; fi
  return 0
}

# Every case: label | want-exit | want-value | env. A bucket case keeps the counts equal (a doc
# inside that bucket's paths), so only the bucket rule can make it functional. The buckets are
# true/false strings as paths-filter writes them; one absent from an override is an empty string.
CASES=(
  "docs only|0|false|DOCS_COUNT=3 CHANGED_COUNT=3 CODE=false DEPS=false CI=false E2E_RELEVANT=false DB_MIGRATION=false I18N=false ASSETS=false"
  "a file outside every bucket|0|true|DOCS_COUNT=2 CHANGED_COUNT=3 CODE=false DEPS=false CI=false E2E_RELEVANT=false DB_MIGRATION=false I18N=false ASSETS=false"
  "only files outside every bucket|0|true|DOCS_COUNT=0 CHANGED_COUNT=1 CODE=false DEPS=false CI=false"
  "a doc inside a code root|0|true|DOCS_COUNT=1 CHANGED_COUNT=1 CODE=true"
  "a doc inside the deps bucket's paths|0|true|DOCS_COUNT=1 CHANGED_COUNT=1 DEPS=true"
  "a doc inside the ci bucket's paths|0|true|DOCS_COUNT=1 CHANGED_COUNT=1 CI=true"
  "a doc inside the e2e_relevant bucket's paths|0|true|DOCS_COUNT=1 CHANGED_COUNT=1 E2E_RELEVANT=true"
  "a doc inside the db_migration bucket's paths|0|true|DOCS_COUNT=1 CHANGED_COUNT=1 DB_MIGRATION=true"
  "a doc inside the i18n bucket's paths|0|true|DOCS_COUNT=1 CHANGED_COUNT=1 I18N=true"
  "a doc inside the assets bucket's paths|0|true|DOCS_COUNT=1 CHANGED_COUNT=1 ASSETS=true"
  "nothing changed|0|false|DOCS_COUNT=0 CHANGED_COUNT=0 CODE=false"
  "counts compared as numbers, not text|0|true|DOCS_COUNT=9 CHANGED_COUNT=10"
  "an override without a docs bucket: every change is functional|0|true|CHANGED_COUNT=1"
  "an override without a docs bucket, nothing changed|0|false|CHANGED_COUNT=0"
  "cannot count the changed files: fail, never docs-only|1|-|DOCS_COUNT=0"
  "a count that is not a number: fail|1|-|DOCS_COUNT=0 CHANGED_COUNT=3x"
  "a docs count that is not a number: fail|1|-|DOCS_COUNT=x CHANGED_COUNT=1"
)

suite() { # suite <body>: 0 when every case holds
  local body=$1 c label rc want envs r=0 why
  for c in "${CASES[@]}"; do
    IFS='|' read -r label rc want envs <<< "$c"
    # shellcheck disable=SC2086 # the env assignments are words on purpose
    if ! why=$(run_case "$body" "$label" "$rc" "$want" $envs); then
      [ "${QUIET:-0}" = 1 ] || bad "$label ($why)"
      r=1
    else
      [ "${QUIET:-0}" = 1 ] || ok "$label"
    fi
  done
  return $r
}

echo "== the functional step, extracted =="
suite "$TMP/functional.sh"

echo "== mutants: each one MUST fail a case =="
mutate() { # mutate <label> <python expression over `text`>
  python3 - "$TMP/functional.sh" "$TMP/mutant.sh" "$2" <<'PY'
import sys
text = open(sys.argv[1]).read()
new = eval(sys.argv[3])
if new == text:
    sys.exit("mutant did not change the step")
open(sys.argv[2], "w").write(new)
PY
  if [ $? -ne 0 ]; then bad "$1 (mutant text no longer matches)"; return; fi
  if QUIET=1 suite "$TMP/mutant.sh"; then bad "mutant survived: $1"; else ok "mutant killed: $1"; fi
}
mutate "a file outside the buckets is not functional (the old inclusion list)" \
  'text.replace("if [ \"$changed\" -gt \"$docs\" ]; then f=true; fi", "", 1)'
mutate "docs-only counted as functional (>=)" 'text.replace("-gt \"$docs\"", "-ge \"$docs\"", 1)'
mutate "an unknown count read as zero" 'text.replace("changed=\"${CHANGED_COUNT:-}\"", "changed=\"${CHANGED_COUNT:-0}\"", 1)'
mutate "a missing docs bucket breaks the comparison" 'text.replace("docs=\"${DOCS_COUNT:-0}\"", "docs=\"${DOCS_COUNT}\"", 1)'
mutate "a non-numeric count accepted" 'text.replace("'"''"' | *[!0-9]*)", "'"''"')", 1)'
for v in CODE DEPS CI E2E_RELEVANT DB_MIGRATION I18N ASSETS; do
  mutate "the $v bucket no longer counts" "text.replace(' \"\$$v\"', '', 1)"
done

echo "== wiring mutants: each one MUST fail the wiring check =="
mutate_yaml() { # mutate_yaml <label> <python expression over `text`>
  python3 - "$HERE/action.yml" "$TMP/action.yml" "$2" <<'PY'
import sys
text = open(sys.argv[1]).read()
new = eval(sys.argv[3])
if new == text:
    sys.exit("mutant did not change the file")
open(sys.argv[2], "w").write(new)
PY
  if [ $? -ne 0 ]; then bad "$1 (mutant text no longer matches)"; return; fi
  if wiring "$TMP/action.yml" > /dev/null 2>&1; then bad "mutant survived: $1"; else ok "mutant killed: $1"; fi
}
mutate_yaml "the count is not a catch-all" \
  "text.replace(\"          changed:\n            - '**'\n\", \"          changed:\n            - 'src/**'\n\", 1)"
mutate_yaml "the count diffs another base" \
  'text.replace("        base: ${{ inputs.base }}\n        filters: |", "        base: HEAD\n        filters: |", 1)'
mutate_yaml "CHANGED_COUNT reads the docs count" \
  'text.replace("CHANGED_COUNT: ${{ steps.all.outputs.changed_count }}", "CHANGED_COUNT: ${{ steps.filter.outputs.docs_count }}", 1)'
mutate_yaml "an expression inside the functional run:" \
  'text.replace("docs=\"${DOCS_COUNT:-0}\"", "docs=\"${{ steps.filter.outputs.docs_count }}\"", 1)'
mutate_yaml "docs takes the whole .claude/ folder again" \
  "text.replace(\"          - '**/LICENSE*'\n\", \"          - '**/LICENSE*'\n          - '.claude/**'\n\", 1)"
mutate_yaml "a test folder drops out of code" "text.replace(\"          - '**/tests/**'\n\", '', 1)"
mutate_yaml "a default bucket without its output" \
  "text.replace(\"        assets:\n          - 'assets/**'\n\", \"        assets:\n          - 'assets/**'\n        tooling:\n          - 'tools/**'\n\", 1)"

echo
echo "detect-changes action: $PASS ok, $FAIL failed"
[ "$FAIL" -eq 0 ]
