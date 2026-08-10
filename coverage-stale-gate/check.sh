#!/usr/bin/env bash
# coverage-stale-gate: stateless throttle for an activity-driven coverage workflow.
# The last qualifying success in the workflow's own run history IS the state —
# no artifact, no cache, no committed timestamp to keep in sync.
#
# Inputs via env (wired in action.yml): GH_TOKEN, GH_REPO, WF, BRANCH,
# MAX_AGE_DAYS, JOB.
#
# Why JOB exists: in the standard pattern the gate and the real coverage job
# live in the SAME workflow, and a throttled run (gate ok, coverage job
# skipped) still completes with run-level conclusion=success. Measured at run
# level, every push resets the staleness clock and real coverage never goes
# stale again after its first run. With JOB set to the coverage job's display
# name, staleness is measured from the last run in which THAT job itself
# concluded success — a skipped job never counts.
set -euo pipefail

# Newest first. Lookback of 100 runs: the per-run jobs lookup below stops at
# the first real success, so it costs one extra API call per throttled run
# since then. If every listed run was throttled we fail OPEN (stale=true):
# worst case is an early coverage run, never a silently disabled gate.
runs=$(gh run list \
  --repo "$GH_REPO" \
  --workflow "$WF" \
  --branch "$BRANCH" \
  --status success \
  --limit 100 \
  --json databaseId,createdAt \
  --jq '.[] | [.databaseId, .createdAt] | @tsv')

last=""
if [ -z "${JOB:-}" ]; then
  # Run-level mode: only sound when this workflow is NOT gated by this action
  # itself — otherwise set `job` so throttled runs don't reset the clock.
  last=$(printf '%s\n' "$runs" | head -n 1 | cut -f 2)
else
  while IFS=$'\t' read -r run_id created_at; do
    [ -z "$run_id" ] && continue
    # Count successful jobs named JOB in this run (env.JOB: injection-safe).
    n=$(gh api "repos/$GH_REPO/actions/runs/$run_id/jobs?per_page=100" \
      --jq '[.jobs[] | select(.name == env.JOB and .conclusion == "success")] | length')
    if [ "$n" -gt 0 ]; then
      last="$created_at"
      break
    fi
  done <<<"$runs"
fi

if [ -z "$last" ]; then
  echo "coverage-stale-gate: no prior successful ${JOB:+job '$JOB' in any }run of $WF on $BRANCH -> STALE (first run)"
  echo "stale=true"    >> "$GITHUB_OUTPUT"
  echo "last_success=" >> "$GITHUB_OUTPUT"
  exit 0
fi

now_s=$(date -u +%s)
last_s=$(date -u -d "$last" +%s)
age_days=$(( (now_s - last_s) / 86400 ))

if [ "$age_days" -ge "$MAX_AGE_DAYS" ]; then
  echo "coverage-stale-gate: last success $last (${age_days}d ago, >= ${MAX_AGE_DAYS}d) -> STALE"
  echo "stale=true" >> "$GITHUB_OUTPUT"
else
  echo "coverage-stale-gate: last success $last (${age_days}d ago, < ${MAX_AGE_DAYS}d) -> throttled"
  echo "stale=false" >> "$GITHUB_OUTPUT"
fi
echo "last_success=$last" >> "$GITHUB_OUTPUT"
