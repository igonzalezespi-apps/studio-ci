#!/usr/bin/env bash
# revert-merge.test.sh — the cases (fixtures/test_revert_merge.py) against a fake `gh`, then the mutants of
# fixtures/mutants.json, each of which MUST make the suite fail.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
rc=0
python3 "$HERE/fixtures/test_revert_merge.py" || rc=1
if [ -z "${SUT_ROOT:-}" ] && [ -z "${SKIP_MUTANTS:-}" ]; then
  echo "== mutants (each one MUST die) =="
  python3 "$HERE/../merge-when-green/testlib/mutate.py" revert-merge/fixtures/test_revert_merge.py "$HERE/fixtures/mutants.json" || rc=1
fi
exit $rc
