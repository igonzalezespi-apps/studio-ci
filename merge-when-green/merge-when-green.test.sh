#!/usr/bin/env bash
# merge-when-green.test.sh — ci-verdict and pr-merge against a fake `gh` (testlib/gh), then the
# mutants of testlib/mutants-*.json, each of which MUST make its suite fail.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
rc=0
echo "== ci-verdict =="
python3 "$HERE/testlib/test_ci_verdict.py" || rc=1
echo "== ci-verdict again, end to end: bash wrapper -> python -> the fake gh BINARY =="
HARNESS_SUBPROCESS=1 python3 "$HERE/testlib/test_ci_verdict.py" || rc=1
echo "== pr-merge =="
python3 "$HERE/testlib/test_pr_merge.py" || rc=1
echo "== config.schema.json and the validator declare the same keys =="
python3 - "$HERE" <<'PY' || rc=1
import json, sys
sys.path.insert(0, sys.argv[1])
import mwg
schema = json.load(open(sys.argv[1] + "/config.schema.json"))
a, b = set(schema["properties"]), set(mwg.CONFIG_KEYS)
print("  ok" if a == b else "  FAIL schema-only %s, validator-only %s" % (sorted(a - b), sorted(b - a)))
sys.exit(0 if a == b else 1)
PY
if [ -z "${SUT_ROOT:-}" ] && [ -z "${SKIP_MUTANTS:-}" ]; then
  echo "== mutants: ci-verdict =="
  python3 "$HERE/testlib/mutate.py" merge-when-green/testlib/test_ci_verdict.py "$HERE/testlib/mutants-ci-verdict.json" || rc=1
  echo "== mutants: pr-merge =="
  python3 "$HERE/testlib/mutate.py" merge-when-green/testlib/test_pr_merge.py "$HERE/testlib/mutants-pr-merge.json" || rc=1
fi
exit $rc
