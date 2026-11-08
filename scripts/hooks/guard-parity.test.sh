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
#   2. WIRING — the guard is actually cabled as a PreToolUse Bash|Monitor|PowerShell
#      hook in the repo's .claude/settings.json (a perfect but un-cabled copy never
#      runs; Monitor and PowerShell run commands too, and a matcher without them
#      lets those through unread, #311).
#   3. LIVENESS — a known-forbidden input actually produces a deny (exit 2). A
#      byte-perfect, well-cabled guard can still be 100% inert (node missing,
#      the extractor throws) and every other check would pass green. This smoke
#      is the only one that proves the guard FIRES, closing the fail-open blind
#      spot the plugin cannot otherwise detect.
#
# A vendored sdd-gate.sh left over from before the SDD phase gate was retired
# (2026-11-07, with OpenSpec) only draws a WARN: it is no longer canonical, so
# there is nothing to compare it with.
#
# Usage: guard-parity.test.sh <path-to-canonical-bash-guard.sh> [<repo-root>]
#   <canonical>  the core-dev copy (e.g. from the installed plugin cache).
#   <repo-root>  defaults to `git rev-parse --show-toplevel`.
# ============================================================================
set -uo pipefail

# HERMETICO FRENTE AL ENTORNO DE GIT. Esta suite crea repos de usar y tirar bajo `mktemp -d` y
# ejecuta `git init`, `git commit`, `git branch -M` y `git update-ref` dentro de ellos. Eso es
# seguro cuando se lanza a mano — y DEJA DE SERLO cuando lo lanza un git hook.
#
# Durante un `git commit`, git exporta `GIT_DIR` (y `GIT_INDEX_FILE`, y a veces `GIT_WORK_TREE`)
# al entorno del hook. **`GIT_DIR` gana sobre el directorio actual**: un `cd /tmp/xxx && git init`
# no crea un repo en /tmp, REINICIA el repo al que apunta `GIT_DIR`. Medido el 2026-08-24 en
# claude-plugins: la suite dejo `core.bare=true`, reescribio `refs/heads/main` a un commit de
# fixture y machaco `refs/remotes/origin/main`. El remoto no se toco, pero el repo local quedo
# inservible y hubo que reconstruirlo desde `origin`.
#
# Un subshell `( cd … )` NO protege de esto: acota el directorio, no el entorno. Lo unico que lo
# acota es limpiar las variables, y hay que hacerlo aqui —en la suite— y no solo en el hook,
# porque la suite es lo que se vendoriza a nueve repos y puede llamarla cualquiera.
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
unset GIT_COMMON_DIR GIT_PREFIX GIT_NAMESPACE GIT_CEILING_DIRECTORIES GIT_CONFIG GIT_CONFIG_GLOBAL

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

# routes(matcher, tool): does a hook group with this matcher run on that tool, as Claude Code reads
# it? None, empty or `*`: every tool. Only names, `|` or `,` and blanks: a list of exact names.
# Anything else: a regex.
MATCHER_JS='
function routes(m, tool) {
  if (m === undefined || m === null || m === "" || m === "*") return true;
  if (typeof m !== "string") return false;
  if (/^[A-Za-z0-9_|, ]+$/.test(m)) return m.split(/[|,]/).map((t) => t.trim()).includes(tool);
  try { return new RegExp("^(?:" + m + ")$").test(tool); } catch (e) { return false; }
}'

# --- 2. Wiring: cabled as PreToolUse Bash|Monitor|PowerShell in settings.json
# One group or several, as long as the three tools reach the guard. guard-sync.sh adds the missing
# ones where Bash is wired.
if [ ! -f "$SETTINGS" ]; then
  echo "FAIL  no $SETTINGS"; fail=$((fail + 1))
elif ! node -e '
  const fs = require("fs");
  const s = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const pre = (s.hooks && s.hooks.PreToolUse) || [];
  const cabled = (tool) => pre.some(g =>
    routes(g.matcher, tool) &&
    (g.hooks || []).some(h => typeof h.command === "string" && h.command.includes("bash-guard.sh")));
  process.exit(["Bash", "Monitor", "PowerShell"].every(cabled) ? 0 : 1);
'"$MATCHER_JS" "$SETTINGS" 2>/dev/null; then
  echo "FAIL  bash-guard.sh is not cabled as a PreToolUse hook for Bash, Monitor and PowerShell in settings.json (re-run guard-sync.sh: it adds the missing ones)"
  fail=$((fail + 1))
else
  echo "OK    wiring: cabled as PreToolUse Bash|Monitor|PowerShell"
fi

# --- 3. Liveness: a known-forbidden input must deny (exit 2) -----------------
# Proves the guard actually FIRES, not just that the file is correct. Feeds the
# real vendored guard the exact harness JSON for `git push origin main` and
# asserts exit 2. If node is missing / the extractor is broken, the guard
# fail-opens (exit 0) and THIS is what catches it.
# The same command from Monitor and PowerShell must deny too (#311).
if [ -f "$VENDORED" ]; then
  for tool in Bash Monitor PowerShell; do
    input='{"tool_name":"'"$tool"'","tool_input":{"command":"git push origin main"}}'
    printf '%s' "$input" | BASH_GUARD_BRANCH="feature/1-x" bash "$VENDORED" >/dev/null 2>&1
    rc=$?
    if [ "$rc" -eq 2 ]; then
      echo "OK    liveness: forbidden input from $tool denied (exit 2), guard fires"
    else
      echo "FAIL  liveness: 'git push origin main' from $tool returned exit $rc (expected 2) — guard is INERT (node missing? extractor broken?)"
      fail=$((fail + 1))
    fi
  done
fi

# --- 3b. Policy: guard.policy.json parses -----------------------------------
# The guard reads a policy it cannot parse as no policy: strict defaults, which keep main protected
# but turn off the opt-in rules, forbidden_paths and one_worktree_per_task among them, without a word
# (#311). The guard cannot deny everything over it (the session that would fix the file is judged by
# the same guard), so the check is here, where pre-push and CI see it.
POLICY="$ROOT/scripts/hooks/guard.policy.json"
if [ -f "$POLICY" ]; then
  if node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$POLICY" 2>/dev/null; then
    echo "OK    policy: guard.policy.json parses"
  else
    echo "FAIL  policy: guard.policy.json does not parse — the guard would run on strict defaults, without its opt-in rules (forbidden_paths, one_worktree_per_task)"
    fail=$((fail + 1))
  fi
fi

# --- 4. A leftover of the retired SDD phase gate ---------------------------
# sdd-gate.sh left the canonical set with OpenSpec. A copy still here is not
# compared nor required to be cabled: it is named, so the repo removes it with
# its PreToolUse hook. Not a failure: the guard itself is unaffected.
if [ -f "$ROOT/scripts/hooks/sdd-gate.sh" ]; then
  echo "WARN  scripts/hooks/sdd-gate.sh is a leftover of the retired SDD phase gate: remove it, its suite, scripts/hooks/fixtures/ and its PreToolUse hook"
fi

echo "----------------------------------------"
if [ "$fail" -eq 0 ]; then echo "OK: vendored guard is intact, cabled and live"; exit 0; fi
echo "FAILURES: $fail"; exit 1
