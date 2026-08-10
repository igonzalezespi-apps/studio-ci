#!/usr/bin/env bash
# Seed cases for ci-gate.
#
# The contract, from the action's own description: fail IFF some job ended in `failure` or
# `cancelled`; `success` and `skipped` both pass — so a path- or label-gated job that was skipped
# never wedges the one required check.
#
# WHY THIS FILE EXISTS AT ALL. ci-gate is the single required check of every consumer: it is the
# one that decides whether a PR is mergeable. A bug here does not look like a bug — it looks like
# "CI is green" or "CI is stuck", and both are believed. It had no test until 2026-08-10, the day
# it broke in production for a reason no reviewer would have caught by reading it.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0
fail=0

# The gate logic, mirroring the action's `run:` block. It is a copy, and the guard against that
# copy drifting is the LAST assertion in this file — which asserts what the real action.yml may
# and may not contain. A behavioural test alone would keep passing while the shipped action
# silently went back to depending on a binary the runner does not have.
gate() { # gate <needs-json> -> prints the report, returns the exit code
  NEEDS_JSON="${1-}" bash -c '
    set -euo pipefail
    json="${NEEDS_JSON:-}"
    [ -n "$json" ] || json="{}"
    all="$(printf "%s" "$json" | jq -r "to_entries | map(\"\(.key)=\(.value.result)\") | join(\", \")")"
    bad="$(printf "%s" "$json" | jq -r "[to_entries[] | select(.value.result == \"failure\" or .value.result == \"cancelled\") | \"\(.key)=\(.value.result)\"] | join(\", \")")"
    if [ -n "$bad" ]; then
      echo "ci-gate: a required job did not pass -> $bad" >&2
      echo "   (all results: $all)" >&2
      exit 1
    fi
    echo "ci-gate: all jobs passed or were skipped ($all)"
  '
}

caso() { # caso <name> <expected-exit> <needs-json>
  local n="$1" want="$2" json="${3-}" out rc
  out="$(gate "$json" 2>&1)"
  rc=$?
  if [ "$rc" -eq "$want" ]; then
    pass=$((pass + 1))
    printf 'ok   — %s (exit %s)\n' "$n" "$rc"
  else
    fail=$((fail + 1))
    printf 'FAIL — %s: expected %s, got %s\n' "$n" "$want" "$rc" >&2
    printf '%s\n' "$out" | sed 's/^/       /' >&2
  fi
}

caso "all success: passes"                  0 '{"a":{"result":"success"},"b":{"result":"success"}}'
caso "skipped passes too"                   0 '{"a":{"result":"success"},"b":{"result":"skipped"}}'
caso "ALL skipped: passes"                  0 '{"a":{"result":"skipped"}}'
caso "one failure: FAILS"                   1 '{"a":{"result":"success"},"b":{"result":"failure"}}'
caso "one cancelled: FAILS"                 1 '{"a":{"result":"cancelled"}}'
caso "failure + cancelled: FAILS"           1 '{"a":{"result":"failure"},"b":{"result":"cancelled"}}'
caso "empty object: passes"                 0 '{}'
caso "empty input: passes"                  0 ''

# The report must NAME the culprit. A gate that only says "something failed" makes you open all
# twelve jobs by hand, and then people stop reading it.
out="$(gate '{"lint":{"result":"success"},"test":{"result":"failure"}}' 2>&1)"
if printf '%s' "$out" | grep -q 'test=failure' && ! printf '%s' "$out" | grep -q 'lint=failure'; then
  pass=$((pass + 1))
  echo "ok   — names the guilty job, and only it"
else
  fail=$((fail + 1))
  echo "FAIL — the report does not identify the culprit: $out" >&2
fi

# DRIFT / REGRESSION GUARD, and the reason this file was written.
#
# A composite action runs on whatever runner its caller uses and cannot declare a toolchain, so
# every binary it names is an undeclared requirement on every consumer. `node` looked free
# because hosted runners preinstall it; a self-hosted runner ships whatever its operator put
# there, and a sensible operator installs no system-wide Node precisely so each repo pins its own
# via setup-node. Measured 2026-08-10, first real run of a consumer on its own runner:
#
#     line 1: node: command not found   /   ##[error]Process completed with exit code 127
#
# …in the AGGREGATE gate, after every other job had already passed.
A="$HERE/action.yml"
if grep -qE '(^|[|&;( ])node[[:space:]]+[-A-Za-z./]' "$A"; then
  fail=$((fail + 1))
  echo "FAIL — action.yml invokes \`node\` again: it is not available on every runner" >&2
  grep -nE '(^|[|&;( ])node[[:space:]]+[-A-Za-z./]' "$A" | sed 's/^/       /' >&2
else
  pass=$((pass + 1))
  echo "ok   — action.yml does not depend on node"
fi

if grep -q 'jq -r' "$A"; then
  pass=$((pass + 1))
  echo "ok   — action.yml still resolves the gate with jq"
else
  fail=$((fail + 1))
  echo "FAIL — action.yml no longer uses jq: the cases above are testing a copy that has drifted" >&2
fi

echo
if [ "$fail" -gt 0 ]; then
  echo "FAIL: $fail/$((pass + fail))" >&2
  exit 1
fi
echo "OK: $pass/$pass"
