#!/usr/bin/env bash
# ============================================================================
# bootstrap.sh — one-time setup for a fresh clone of this public config repo
# ============================================================================
# Idempotent; safe to re-run. It:
#   1. cables the local private-reference git hook (no-op off-machine);
#   2. installs the Claude Code plugins this repo declares (project scope);
#   3. refreshes + verifies the vendored bash-guard when the plugin scripts are
#      reachable (guard-sync / guard-verify ship in the core-dev plugin);
#   4. always runs the vendored guard self-test as a portable sanity check.
#
# Steps 2-3 are best-effort: on a fork or any machine without the maintainer's
# plugin marketplace they are skipped with a note, and the repo keeps enforcing
# through its committed vendored copy.
# ============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

echo "==> Cabling the local git hooks (private-reference guard; no-op where the denylist is absent)"
git config core.hooksPath .githooks

echo "==> Installing declared Claude Code plugins (project scope)"
PLUGINS=(core-dev studio-policy)
if command -v claude >/dev/null 2>&1; then
  for plugin in "${PLUGINS[@]}"; do
    if claude plugin install "${plugin}@ivan" --scope project; then
      echo "    installed ${plugin}@ivan"
    else
      echo "    warn: could not install ${plugin}@ivan (add the 'ivan' marketplace first)" >&2
    fi
  done
else
  echo "    warn: 'claude' CLI not found on PATH — skipping plugin install" >&2
fi

# Locate a script shipped by the core-dev plugin. When Claude Code runs a plugin
# command it exposes CLAUDE_PLUGIN_ROOT; from a plain shell we search the plugin
# cache. Prints nothing when not found.
#
# The search is deliberately ORDERED and never `head -1` over a bare find. Two reasons,
# both measured on a real machine 2026-07-21:
#
#   1. `find ~/.claude -path '*core-dev*' | head -1` returns whatever the filesystem
#      hands back first. On this machine that set contains the SAME plugin served from
#      two different marketplaces — the maintainer's own, and a read-only MIRROR of it
#      published to a downstream partner org. Picking by luck means a repo can end up
#      vendoring its guard from the mirror, which is a copy that may lag the canonical
#      source. A supply chain that flows the wrong way is worth ruling out even while
#      the two copies still happen to be byte-identical.
#   2. The cache is keyed by plugin VERSION (…/core-dev/<version>/scripts/…), so with
#      two versions cached, `head -1` can hand back the older one. Sort by version and
#      take the newest.
#
# Ordered roots: the marketplace this repo actually declares, then any other cache
# entry, then any other marketplace checkout. Called through `bash` so a missing
# execute bit on a cached file never turns into a silent skip.
CANONICAL_MARKETPLACE="${STUDIO_MARKETPLACE:-ivan}"

find_plugin_script() {
  local name="$1" root hit
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/scripts/${name}" ]; then
    printf '%s' "${CLAUDE_PLUGIN_ROOT}/scripts/${name}"
    return 0
  fi
  for root in \
    "${HOME}/.claude/plugins/cache/${CANONICAL_MARKETPLACE}/core-dev" \
    "${HOME}/.claude/plugins/marketplaces/${CANONICAL_MARKETPLACE}/plugins/core-dev" \
    "${HOME}/.claude/plugins/cache" \
    "${HOME}/.claude/plugins/marketplaces"; do
    [ -d "$root" ] || continue
    # sort -V so a version-keyed cache yields the NEWEST, not an arbitrary one.
    hit="$(find "$root" -type f -name "$name" -path '*core-dev*' 2>/dev/null | sort -V | tail -1)"
    if [ -n "$hit" ]; then
      printf '%s' "$hit"
      return 0
    fi
  done
}

echo "==> Refreshing the vendored guard from the canonical core (if the plugin is present)"
SYNC="$(find_plugin_script guard-sync.sh || true)"
if [ -n "${SYNC:-}" ]; then
  bash "$SYNC" --repo "$ROOT" || echo "    warn: guard-sync reported an issue" >&2
else
  echo "    note: guard-sync.sh not found — leaving the committed vendored copy as-is"
fi

echo "==> Verifying the vendored guard (parity + wiring + liveness)"
VERIFY="$(find_plugin_script guard-verify.sh || true)"
if [ -n "${VERIFY:-}" ]; then
  bash "$VERIFY" --repo "$ROOT"
else
  echo "    note: guard-verify.sh not found — run /guard-verify from Claude Code to check parity/wiring/liveness"
fi

echo "==> Running the vendored guard self-test"
bash scripts/hooks/bash-guard.test.sh

echo "==> Bootstrap complete"
