#!/usr/bin/env bash
# action.test.sh — runs the body of risk-class/action.yml (extracted, not copied) with the exact
# shell of GitHub (`bash --noprofile --norc -e -o pipefail`) against a fake `gh`, so the step is
# proven to report its output and to fail closed, not just to parse.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
python3 - "$HERE/action.yml" "$TMP/step.sh" <<'PY'
import sys, yaml, pathlib
d = yaml.safe_load(open(sys.argv[1]))
steps = [s for s in d["runs"]["steps"] if "run" in s]
assert len(steps) == 1, "expected one run step"
pathlib.Path(sys.argv[2]).write_text(steps[0]["run"])
PY
# a shim named `gh` that understands --jq/-f/--silent for this step's label calls, and forwards
# plain `gh api -i` calls of the classifier to the shared fake
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" --jq "*) echo "semver:patch"; echo "riesgo:3"; exit 0 ;;
  *" -f "*|*" --silent"*) printf '%s\n' "\$*" >> "$TMP/labels.log"; exit 0 ;;
esac
exec python3 "$HERE/../merge-when-green/testlib/gh" "\$@"
SH
chmod +x "$TMP/bin/gh"
python3 - "$HERE/../merge-when-green/testlib" "$TMP/db.json" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import harness as H
w = H.World(); w.policy(); w.pull(7); w.files(7, ["docs/a.md"])
w.save(sys.argv[2])
PY
pass=0; fail=0
run_step() { # run_step <apply> <db>
  : > "$TMP/out"; : > "$TMP/summary"; : > "$TMP/log"; : > "$TMP/labels.log"
  PATH="$TMP/bin:$PATH" FAKE_GH_DB="$2" FAKE_GH_LOG="$TMP/log" GITHUB_OUTPUT="$TMP/out" GITHUB_STEP_SUMMARY="$TMP/summary" \
    GITHUB_ACTION_PATH="$HERE" GH_TOKEN=x PR_NUMBER=7 PR_REPO=acme/proyecto CONFIG_PATH=.github/merge-when-green.json APPLY="$1" \
    bash --noprofile --norc -e -o pipefail "$TMP/step.sh" > "$TMP/stdout" 2>&1
}
check() { if eval "$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL $1"; cat "$TMP/stdout"; fi; }
run_step false "$TMP/db.json"; rc=$?
check "docs PR -> class 0 in the outputs" '[ $rc -eq 0 ] && grep -qx "class=0" "$TMP/out" && grep -qx "label=riesgo:0" "$TMP/out"'
check "summary written" 'grep -q "risk-class: riesgo:0" "$TMP/summary"'
check "read-only without apply-label" '[ ! -s "$TMP/labels.log" ]'
run_step true "$TMP/db.json"; rc=$?
check "apply-label removes the stale riesgo:3 and sets riesgo:0" 'grep -q "DELETE repos/acme/proyecto/issues/7/labels/riesgo%3A3" "$TMP/labels.log" && grep -q "labels\[\]=riesgo:0" "$TMP/labels.log"'
python3 -c "import json; d=json.load(open('$TMP/db.json')); d['routes'].pop('GET repos/acme/proyecto/pulls/7/files?per_page=100'); json.dump(d, open('$TMP/db2.json','w'))"
run_step false "$TMP/db2.json"; rc=$?
check "cannot measure -> the step fails (never a silent riesgo-0)" '[ $rc -ne 0 ] && ! grep -q "class=" "$TMP/out"'
echo "risk-class action: $pass/$((pass+fail)) cases pass"
[ "$fail" -eq 0 ]
