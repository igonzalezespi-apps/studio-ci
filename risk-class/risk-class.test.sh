#!/usr/bin/env bash
# risk-class.test.sh — the classification table, the ways an author could lower a class, the API
# collector against a fake `gh`, and the mutants that must die (fixtures/mutants.json).
# Uses: python3 + the fake gh in merge-when-green/testlib. No network.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
rc=0
echo "== cases =="
python3 "$HERE/fixtures/test_risk_class.py" || rc=1
if [ -z "${SUT_ROOT:-}" ] && [ -z "${SKIP_MUTANTS:-}" ]; then
  echo "== mutants (each one MUST die) =="
  python3 "$HERE/../merge-when-green/testlib/mutate.py" risk-class/fixtures/test_risk_class.py "$HERE/fixtures/mutants.json" || rc=1
fi
exit $rc
