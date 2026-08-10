#!/usr/bin/env bash
# ============================================================================
# guard-parity.test.sh — vendored-guard integrity + liveness check
# ============================================================================
# Runs in a CONSUMING repo (and in pre-push / CI) to prove three things about
# its vendored copy of bash-guard.sh:
#
#   1. PARITY — the vendored bash-guard.sh has not diverged from the canonical
#      core in core-dev. The code is byte-identical across repos; only the
#      separate guard.policy.json differs, so bash-guard.sh must match exactly.
#   2. WIRING — the guard is actually cabled as a PreToolUse Bash hook in the
#      repo's .claude/settings.json (a perfect but un-cabled copy never runs).
#   3. LIVENESS — a known-forbidden input actually produces a deny (exit 2). A
#      byte-perfect, well-cabled guard can still be 100% inert (node missing,
#      the extractor throws) and every other check would pass green. This smoke
#      is the only one that proves the guard FIRES, closing the fail-open blind
#      spot the plugin cannot otherwise detect.
#
# Plus, ONLY when the repo has adopted the D8 phase gate (a vendored sdd-gate.sh
# is present), a 4th check: sdd-gate PARITY + WIRING (its behaviour is covered by
# the vendored sdd-gate.test.sh). Repos without the gate skip it silently.
#
# Usage: guard-parity.test.sh <path-to-canonical-bash-guard.sh> [<repo-root>]
#   <canonical>  the core-dev copy (e.g. from the installed plugin cache).
#   <repo-root>  defaults to `git rev-parse --show-toplevel`.
# ============================================================================
set -uo pipefail

CANON="${1:-}"
ROOT="${2:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -n "$CANON" ] && [ -f "$CANON" ] || { echo "usage: guard-parity.test.sh <canonical bash-guard.sh> [repo-root]" >&2; exit 1; }

VENDORED="$ROOT/scripts/hooks/bash-guard.sh"
SETTINGS="$ROOT/.claude/settings.json"
fail=0

# --- 1. Parity: vendored core == canonical core (byte-for-byte) -------------
if [ ! -f "$VENDORED" ]; then
  echo "FAIL  no vendored guard at $VENDORED"; fail=$((fail + 1))
elif ! diff -q "$CANON" "$VENDORED" >/dev/null 2>&1; then
  echo "FAIL  vendored bash-guard.sh has diverged from the canonical core:"
  diff "$CANON" "$VENDORED" | head -20
  fail=$((fail + 1))
else
  echo "OK    parity: vendored core == canonical"
fi

# --- 2. Wiring: cabled as PreToolUse Bash in settings.json ------------------
if [ ! -f "$SETTINGS" ]; then
  echo "FAIL  no $SETTINGS"; fail=$((fail + 1))
elif ! node -e '
  const fs = require("fs");
  const s = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const pre = (s.hooks && s.hooks.PreToolUse) || [];
  const cabled = pre.some(g =>
    (g.matcher || "").split("|").includes("Bash") &&
    (g.hooks || []).some(h => typeof h.command === "string" && h.command.includes("bash-guard.sh")));
  process.exit(cabled ? 0 : 1);
' "$SETTINGS" 2>/dev/null; then
  echo "FAIL  bash-guard.sh is not cabled as a PreToolUse Bash hook in settings.json"
  fail=$((fail + 1))
else
  echo "OK    wiring: cabled as PreToolUse Bash"
fi

# --- 3. Liveness: a known-forbidden input must deny (exit 2) -----------------
# Proves the guard actually FIRES, not just that the file is correct. Feeds the
# real vendored guard the exact harness JSON for `git push origin main` and
# asserts exit 2. If node is missing / the extractor is broken, the guard
# fail-opens (exit 0) and THIS is what catches it.
if [ -f "$VENDORED" ]; then
  input='{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}'
  printf '%s' "$input" | BASH_GUARD_BRANCH="feature/1-x" bash "$VENDORED" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 2 ]; then
    echo "OK    liveness: forbidden input denied (exit 2), guard fires"
  else
    echo "FAIL  liveness: 'git push origin main' returned exit $rc (expected 2) — guard is INERT (node missing? extractor broken?)"
    fail=$((fail + 1))
  fi
fi

# --- 4. D8 phase-gate: parity + wiring (only if the repo adopted it) --------
# sdd-gate.sh is the portable half of the phase gate — it reads only branch+phase
# from the state file, so it travels byte-for-byte like bash-guard. A repo that
# vendored it must keep it identical to the core AND cabled, or the gate silently
# stops governing. Skipped entirely for a repo that never adopted the gate.
# Behaviour is covered by the vendored sdd-gate.test.sh; this is the integrity +
# wiring smoke, matching what checks 1-2 do for bash-guard.
SDD_VENDORED="$ROOT/scripts/hooks/sdd-gate.sh"
SDD_CANON="$(dirname "$CANON")/sdd-gate.sh"
if [ -f "$SDD_VENDORED" ]; then
  if [ ! -f "$SDD_CANON" ]; then
    echo "WARN  sdd-gate vendored but canonical not found next to $CANON — parity unchecked"
  elif ! diff -q "$SDD_CANON" "$SDD_VENDORED" >/dev/null 2>&1; then
    echo "FAIL  vendored sdd-gate.sh has diverged from the canonical core:"
    diff "$SDD_CANON" "$SDD_VENDORED" | head -20
    fail=$((fail + 1))
  else
    echo "OK    parity: vendored sdd-gate == canonical"
  fi

  if [ ! -f "$SETTINGS" ]; then
    echo "FAIL  no $SETTINGS (sdd-gate wiring uncheckable)"; fail=$((fail + 1))
  elif ! node -e '
    const fs = require("fs");
    const s = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const pre = (s.hooks && s.hooks.PreToolUse) || [];
    const cabled = pre.some(g =>
      (g.hooks || []).some(h => typeof h.command === "string" && h.command.includes("sdd-gate.sh")));
    process.exit(cabled ? 0 : 1);
  ' "$SETTINGS" 2>/dev/null; then
    echo "FAIL  sdd-gate.sh is vendored but not cabled as a PreToolUse hook in settings.json"
    fail=$((fail + 1))
  else
    echo "OK    wiring: sdd-gate cabled as PreToolUse"
  fi

  # The suite's fixtures must be here too. sdd-gate.test.sh skips its
  # fixture-driven cases with a plain `[ -f ... ]` guard, so a consumer missing
  # them runs a SMALLER suite and still reports OK — the two cases lost are the
  # ones taken from a real session transcript, which is exactly the evidence a
  # consumer cannot reconstruct on its own. Silent shrinkage, green output.
  SDD_FIX_CANON="$(dirname "$CANON")/fixtures"
  if [ -d "$SDD_FIX_CANON" ]; then
    missing=""
    for f in "$SDD_FIX_CANON"/*.json; do
      [ -e "$f" ] || continue
      [ -f "$ROOT/scripts/hooks/fixtures/$(basename "$f")" ] || missing="$missing $(basename "$f")"
    done
    if [ -n "$missing" ]; then
      echo "FAIL  sdd-gate is vendored but its test fixtures are not:$missing (re-run guard-sync.sh)"
      fail=$((fail + 1))
    else
      echo "OK    fixtures: sdd-gate suite has its fixtures, full case count runs"
    fi
  fi
fi

echo "----------------------------------------"
if [ "$fail" -eq 0 ]; then echo "OK: vendored guard is intact, cabled and live"; exit 0; fi
echo "FAILURES: $fail"; exit 1
