#!/usr/bin/env bash
# ============================================================================
# bash-guard.sh — PreToolUse guard (matcher: Bash) for Claude Code
# ============================================================================
# Canonical source: plugins/core-dev of igonzalezespi/claude-plugins. This file
# is VENDORED (committed) into each consuming repo and cabled from its
# settings.json — it is NOT a plugin hook, because ${CLAUDE_PLUGIN_ROOT} does
# not exist inside a git hook and a repo must keep enforcing without the plugin.
# The universal core is identical across repos; everything repo-specific lives
# in guard.policy.json next to this file.
#
# Harness contract: reads the tool-call JSON from STDIN
#   {"tool_name":"Bash","tool_input":{"command":"..."}, ...}
# and emits a verdict:
#   - allow → exit 0, no output
#   - deny  → exit 2 + "bash-guard DENY: <reason>. Alternative: <what to do>"
#             on stderr (the harness blocks the command and the agent reads the
#             reason to self-correct instead of retrying blindly)
#
# ⚠️ TRIPWIRE — THIS IS NOT A SECURITY BOUNDARY ⚠️
# A best-effort firewall against agent mistakes, not hermetic: obfuscated forms
# — `bash -c "..."`, git aliases, `git -c ...`, variable expansion ($CMD),
# intermediate scripts, quoted text the simple tokenizer does not interpret,
# exotic chaining — are NOT guaranteed to be intercepted. The guard is also
# fail-open: if command extraction fails (node absent, malformed JSON), it
# allows — a broken tripwire must not take down the harness.
#
# And there is NO server-side backstop behind it. The consuming repos have no
# branch protection and no required status checks (measured across the fleet:
# `branches/<ref>/protection` -> 404 and `rulesets` -> [] nearly everywhere; the
# one existing ruleset only blocks deletion/force-push and does not gate on CI)
# — a deliberate standing decision, not an oversight. So when this guard misses
# something, what is left is: the local git hooks (pre-commit / commit-msg /
# pre-push), a CI that REPORTS without blocking (no required checks -> a red run
# does not stop a merge), and human review. Treat an escape here as a real
# escape; nothing on the server is going to catch it.
#
# BASH_GUARD_BRANCH: override of the current branch, TEST-ONLY (bash-guard.test.sh)
# — lets the suite simulate "on main"/"on a PR branch" deterministically. In
# production the branch resolves via `git branch --show-current` (empty in
# detached HEAD or outside a repo → treated as not-main).
# BASH_GUARD_POLICY: override of the policy path, TEST-ONLY.
# BASH_GUARD_PR_BASE: override of a PR's base branch, TEST-ONLY (avoids a network
# call to gh in the merge-to-integration check).
# BASH_GUARD_PR_HEAD: override of a PR's head branch, TEST-ONLY (same lookup).
# Setting either of the two puts the resolver in test mode; see pr_refs.
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Policy (repo-specific parameters; strict defaults if absent) ------------
# Read once via node into shell-safe variables. Missing/invalid file → strict
# defaults: no generated trees, agent may not merge, main protected, egress
# restricted to localhost. Strict-by-default: an absent policy never weakens.
POLICY_FILE="${BASH_GUARD_POLICY:-$HERE/guard.policy.json}"
# The reader itself, kept in a variable: the SAME strict-defaults parser has to serve
# both this repo's policy and (in check_pr_merge) a target repo's. Two copies would
# drift, and the one that drifted would be the one nobody runs locally.
POLICY_READER='
const fs = require("fs");
let p = {};
try { p = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch (e) {}
const trees = Array.isArray(p.generated_trees) ? p.generated_trees : [];
const regen = typeof p.generated_regen_hint === "string" ? p.generated_regen_hint : "";
const merge = p.agent_may_merge === true ? "true" : "false";
const prot = typeof p.protected_branch === "string" && p.protected_branch ? p.protected_branch : "main";
const integ = typeof p.integration_branch === "string" && p.integration_branch ? p.integration_branch : "";
const longLived = Array.isArray(p.long_lived_branches) ? p.long_lived_branches : [];
const egress = Array.isArray(p.egress_allow) && p.egress_allow.length
  ? p.egress_allow : ["localhost", "127.0.0.1", "::1"];
const out = [];
out.push("MERGE\t" + merge);
out.push("PROTECTED\t" + prot);
out.push("INTEGRATION\t" + integ);
for (const b of longLived) if (typeof b === "string" && b) out.push("LONGLIVED\t" + b);
out.push("REGEN\t" + regen);
for (const t of trees) if (typeof t === "string" && t) out.push("TREE\t" + t);
for (const h of egress) if (typeof h === "string" && h) out.push("EGRESS\t" + h);
process.stdout.write(out.join("\n") + "\n");
'
POLICY_TSV="$(node -e "$POLICY_READER" "$POLICY_FILE" 2>/dev/null || true)"

AGENT_MAY_MERGE=false
PROTECTED_BRANCH=main
INTEGRATION_BRANCH=""
LONG_LIVED_BRANCHES=()
GEN_REGEN_HINT=""
GEN_TREES=()
EGRESS_ALLOW=()
if [ -n "$POLICY_TSV" ]; then
  while IFS=$'\t' read -r key val; do
    case "$key" in
      MERGE) AGENT_MAY_MERGE="$val" ;;
      PROTECTED) PROTECTED_BRANCH="$val" ;;
      INTEGRATION) INTEGRATION_BRANCH="$val" ;;
      LONGLIVED) [ -n "$val" ] && LONG_LIVED_BRANCHES+=("$val") ;;
      REGEN) GEN_REGEN_HINT="$val" ;;
      TREE) [ -n "$val" ] && GEN_TREES+=("$val") ;;
      EGRESS) [ -n "$val" ] && EGRESS_ALLOW+=("$val") ;;
    esac
  done <<<"$POLICY_TSV"
fi
# Fallback if the policy provided no egress allow-list (defensive; the node
# reader already defaults, but never leave the list empty → would allow all).
if [ "${#EGRESS_ALLOW[@]}" -eq 0 ]; then
  EGRESS_ALLOW=("localhost" "127.0.0.1" "::1")
fi

deny() {
  printf 'bash-guard DENY: %s. Alternative: %s\n' "$1" "$2" >&2
  exit 2
}

current_branch() {
  # The override exists only to make the test suite deterministic.
  if [ -n "${BASH_GUARD_BRANCH:-}" ]; then
    printf '%s' "$BASH_GUARD_BRANCH"
    return 0
  fi
  git branch --show-current 2>/dev/null || true
}

# Is the path a real environment file? (.env.example templates are not)
is_env_file() {
  local base="${1##*/}"
  case "$base" in
    .env.example | env.example) return 1 ;;
    # Also unexpanded glob patterns (.env*, .env?) that would cover the real
    # files when executed.
    .env | .env.* | '.env*'* | '.env?'*) return 0 ;;
  esac
  return 1
}

deny_generated() {
  local tree="$1" offender="$2"
  local hint="${GEN_REGEN_HINT:-regenerate it from its source instead of editing it by hand}"
  deny "write into ${tree}/ (auto-generated tree): '$offender'" "$hint"
}

deny_merge_strategy() {
  deny "git merge with -X ours/theirs silently suppresses conflicts" \
    "merge without -X and resolve the conflicts by hand"
}

deny_human_merge() {
  deny "$1" \
    "merging a PR into the protected branch is a human-only action: leave the PR ready (green checks) and wait"
}

# --- Per-command rules ------------------------------------------------------

# Redirections (>, >>, &>) whose target is inside a generated tree. Applies to
# any command in the segment, not just the writer list. No-op if the policy
# declares no generated trees (short-circuit — an empty tree must NOT match
# every absolute-path redirection).
check_generated_redirect() {
  local seg="$1" tree re
  [ "${#GEN_TREES[@]}" -eq 0 ] && return 0
  for tree in "${GEN_TREES[@]}"; do
    re=">[[:space:]]*[^[:space:]]*${tree}/"
    if [[ "$seg" =~ $re ]]; then
      deny_generated "$tree" 'redirection into the generated tree'
    fi
  done
  return 0
}

check_git() {
  # Skip git global options (those that take a separate value, in pairs) to
  # locate the real subcommand. `git -c x=y push` obfuscation is not guaranteed
  # (see header).
  local i=1 sub=""
  while [ "$i" -lt "${#tok[@]}" ]; do
    case "${tok[i]}" in
      -c | -C | --git-dir | --work-tree | --namespace | --exec-path) i=$((i + 2)) ;;
      -*) i=$((i + 1)) ;;
      *)
        sub="${tok[i]}"
        i=$((i + 1))
        break
        ;;
    esac
  done
  case "$sub" in
    push) check_git_push "$i" ;;
    commit) check_git_commit ;;
    merge) check_git_merge ;;
  esac
  return 0
}

check_git_push() {
  local i="$1"
  local force=0 noverify=0 a
  local -a positional=()
  while [ "$i" -lt "${#tok[@]}" ]; do
    a="${tok[i]}"
    i=$((i + 1))
    case "$a" in
      --no-verify) noverify=1 ;;
      # --force-with-lease is evaluated per target (only allowed toward != protected)
      --force-with-lease | --force-with-lease=* | --force-if-includes) ;;
      --force) force=1 ;;
      --all | --mirror | --branches)
        deny "git push ${a} pushes every branch, including ${PROTECTED_BRANCH}" \
          "push only your PR branch: git push -u origin HEAD"
        ;;
      # Push flags with a value in a separate token
      -o | --push-option | --repo | --receive-pack | --exec) i=$((i + 1)) ;;
      --*) ;;
      -?*)
        # Short cluster: -f anywhere is --force; -n is --dry-run on push
        # (harmless, allowed).
        if [[ "$a" == -*f* ]]; then force=1; fi
        ;;
      *) positional+=("$a") ;;
    esac
  done

  if [ "$noverify" -eq 1 ]; then
    deny "git push --no-verify skips the pre-push gate (format+lint)" \
      "push without --no-verify and, if the hook fails, fix the root cause"
  fi
  if [ "$force" -eq 1 ]; then
    deny "git push --force/-f can rewrite remote history" \
      "use git push --force-with-lease toward your PR branch (never toward ${PROTECTED_BRANCH})"
  fi

  # Resolve the push target(s). positional[0] is the remote (name or URL); the
  # rest are refspecs <src>:<dst> (without ':' the target is the ref itself;
  # HEAD resolves to the current branch).
  local -a refspecs=()
  if [ "${#positional[@]}" -gt 1 ]; then
    refspecs=("${positional[@]:1}")
  fi

  if [ "${#refspecs[@]}" -eq 0 ]; then
    # push with no refspec: with push.default=simple the target is the current branch
    if [ "$(current_branch)" = "$PROTECTED_BRANCH" ]; then
      deny "git push from ${PROTECTED_BRANCH} pushes directly to ${PROTECTED_BRANCH}" \
        "work on a PR branch (git checkout -b <type>/<issue>-description) and open a PR"
    fi
    return 0
  fi

  local r dst
  for r in "${refspecs[@]}"; do
    r="${r#+}"
    if [[ "$r" == *:* ]]; then
      dst="${r#*:}"
    else
      dst="$r"
    fi
    dst="${dst#refs/heads/}"
    if [ -z "$dst" ]; then continue; fi
    if [ "$dst" = "HEAD" ]; then
      dst="$(current_branch)"
    fi
    if [ "$dst" = "$PROTECTED_BRANCH" ]; then
      deny "push targeting ${PROTECTED_BRANCH} is forbidden (${PROTECTED_BRANCH} is protected for humans)" \
        "push to your PR branch (git push -u origin HEAD) and open a PR"
    fi
  done
  return 0
}

check_git_commit() {
  local a
  for a in "${tok[@]}"; do
    if [ "$a" = "--no-verify" ]; then
      deny "git commit --no-verify skips the pre-commit hooks" \
        "commit without --no-verify and, if the hook fails, fix the root cause"
    fi
    # On commit, -n (even clustered, e.g. -an) is equivalent to --no-verify.
    if [[ "$a" =~ ^-[A-Za-z]*n[A-Za-z]*$ ]]; then
      deny "git commit -n is equivalent to --no-verify (skips the pre-commit hooks)" \
        "commit without -n and, if the hook fails, fix the root cause"
    fi
  done
  return 0
}

check_git_merge() {
  local i a nxt
  for ((i = 0; i < ${#tok[@]}; i++)); do
    a="${tok[i]}"
    case "$a" in
      -Xours | -Xtheirs) deny_merge_strategy ;;
      -X | --strategy-option)
        nxt="${tok[i + 1]:-}"
        if [ "$nxt" = "ours" ] || [ "$nxt" = "theirs" ]; then
          deny_merge_strategy
        fi
        ;;
      --strategy-option=ours | --strategy-option=theirs) deny_merge_strategy ;;
    esac
  done
  return 0
}

# Resolve a PR's base AND head branch (for `gh pr merge <n>`) in ONE lookup, so
# the guard can (a) allow a merge into the integration branch while always
# denying a merge into the protected branch, and (b) refuse to merge a PR whose
# HEAD is a long-lived branch. Emits "<base><TAB><head>".
#
# Why the head matters, measured: every repo in this fleet has
# `delete_branch_on_merge: true`, and GitHub deletes the head branch on merge
# unless it is the repository's DEFAULT branch. In a develop-default repo the
# release PR (head `develop`) is therefore safe, but a back-merge opened with
# head `main` deletes `main` on merge. That is not hypothetical: measured in one
# of the maintainer's repos, a back-merge merged at 2026-08-24T17:47:18Z was
# followed by `DeleteEvent branch main` three seconds later, taking the release
# line and every tag reachable only from it. The correct shape is a throwaway
# branch cut from `main` (`chore/back-merge-main-a-develop`), which a sibling
# repo used for the very same operation — and why its `main` survived.
#
# TEST-ONLY overrides BASH_GUARD_PR_BASE / BASH_GUARD_PR_HEAD avoid the network
# call. Setting EITHER puts the resolver in test mode; the one left unset falls
# back to a neutral value (the protected branch for base — fail closed; a work
# branch for head — so the pre-existing base-only cases keep their verdicts).
#
# Fails CLOSED: if the refs cannot be determined, return the protected branch
# for both, so the merge is denied.
pr_refs() {
  local pr="$1" repo="${2:-}"
  if [ -n "${BASH_GUARD_PR_BASE:-}" ] || [ -n "${BASH_GUARD_PR_HEAD:-}" ]; then
    printf '%s\t%s' "${BASH_GUARD_PR_BASE:-$PROTECTED_BRANCH}" "${BASH_GUARD_PR_HEAD:-feature/test-head}"
    return 0
  fi
  local refs
  # The `--repo` of the original command MUST be forwarded. The hook runs with
  # `cd "$CLAUDE_PROJECT_DIR"`, so without it `gh pr view` resolves the number
  # against the SESSION's repo, not the PR's. Measured from ~/work against a
  # product PR: "Could not resolve to a PullRequest with the number of 439",
  # which the fail-closed branch below turns into the protected branch — so
  # every cross-repo merge was denied no matter what the policy said.
  if [ -n "$repo" ]; then
    refs="$(gh pr view "$pr" --repo "$repo" --json baseRefName,headRefName \
      -q '.baseRefName + "\t" + .headRefName' 2>/dev/null || true)"
  else
    refs="$(gh pr view "$pr" --json baseRefName,headRefName \
      -q '.baseRefName + "\t" + .headRefName' 2>/dev/null || true)"
  fi
  case "$refs" in
    # Both fields present and non-empty. Anything else is an unresolved PR.
    ?*$'\t'?*) printf '%s' "$refs" ;;
    *) printf '%s\t%s' "$PROTECTED_BRANCH" "$PROTECTED_BRANCH" ;;
  esac
}

# Back-compat shim: the base alone, for callers/tests that only need it.
pr_base_branch() {
  local refs
  refs="$(pr_refs "$1" "${2:-}")"
  printf '%s' "${refs%%$'\t'*}"
}

# Is this branch name long-lived — i.e. one whose deletion loses history rather
# than throwing away a finished work branch? The policy may extend the set via
# `long_lived_branches`; the floor below is built in and cannot be configured
# away, because a policy that omits it must never be weaker than one that does.
is_long_lived_branch() {
  local b="$1" x
  [ -z "$b" ] && return 1
  case "$b" in
    main | master | develop | development | trunk) return 0 ;;
  esac
  [ "$b" = "$PROTECTED_BRANCH" ] && return 0
  [ -n "$INTEGRATION_BRANCH" ] && [ "$b" = "$INTEGRATION_BRANCH" ] && return 0
  for x in ${LONG_LIVED_BRANCHES[@]+"${LONG_LIVED_BRANCHES[@]}"}; do
    [ "$b" = "$x" ] && return 0
  done
  return 1
}

# Which repo is the SESSION rooted in? The hook runs with `cd "$CLAUDE_PROJECT_DIR"`,
# so this is the repo whose guard.policy.json was loaded at the top of this file.
# Emits "<owner>/<name>", or nothing when the cwd is not a git repo with an origin.
# TEST-ONLY override: BASH_GUARD_SESSION_REPO.
session_repo() {
  if [ -n "${BASH_GUARD_SESSION_REPO+x}" ]; then
    printf '%s' "$BASH_GUARD_SESSION_REPO"
    return 0
  fi
  local url
  url="$(git config --get remote.origin.url 2>/dev/null || true)"
  [ -n "$url" ] || return 0
  # The last two path segments, for both spellings:
  #   https://github.com/owner/name.git   git@github.com:owner/name.git
  printf '%s' "$url" | sed -E 's#\.git$##; s#/$##; s#^.*[:/]([^/]+)/([^/]+)$#\1/\2#'
}

# Turn a guard.policy.json FILE into the same TSV the top of this script parses.
# Extracted so the identical strict-defaults reader serves both the session's
# policy and a target repo's — two readers would drift, and the one that drifted
# would be the one nobody runs locally.
policy_tsv_from_file() {
  node -e "$POLICY_READER" "$1" 2>/dev/null || true
}

# The guard policy of ANOTHER repo, read from its origin. Empty output = could not
# read it, which the caller MUST treat as a denial.
# TEST-ONLY override: BASH_GUARD_TARGET_POLICY (a file path).
target_policy_tsv() {
  local repo="$1" content tmp tsv
  if [ -n "${BASH_GUARD_TARGET_POLICY:-}" ]; then
    policy_tsv_from_file "$BASH_GUARD_TARGET_POLICY"
    return 0
  fi
  content="$(gh api "repos/${repo}/contents/scripts/hooks/guard.policy.json" --jq .content 2>/dev/null \
    | base64 -d 2>/dev/null || true)"
  [ -n "$content" ] || return 0
  tmp="$(mktemp)" || return 0
  printf '%s' "$content" > "$tmp"
  tsv="$(policy_tsv_from_file "$tmp")"
  rm -f "$tmp"
  printf '%s' "$tsv"
}

# A `gh pr merge` attempt. Three independent negatives, in this order:
#   1. the policy does not grant agent_may_merge;
#   2. the base is the protected branch (human-only, per contract) — this one
#      does NOT depend on the policy and no configuration can switch it off;
#   3. the head is a long-lived branch, which `delete_branch_on_merge` would
#      destroy at merge time.
# Denying (3) can never block a merge the agent could otherwise perform: the one
# legitimate PR with a long-lived head is the release (head `develop`, base
# `main`), and (2) already denies that.
#
# WHOSE POLICY DECIDES. Until 1.9.0 it was always the SESSION's, because the hook
# starts with `cd "$CLAUDE_PROJECT_DIR"` and that is the only policy it had read.
# That was harmless only by accident: the repos whose policy says
# `agent_may_merge: false` had no integration branch, so every one of their PRs
# targeted the protected branch — and negative (2) does not consult any policy.
# The moment such a repo gains an integration branch, a session rooted somewhere
# permissive could merge into it against that repo's own policy.
# So a merge naming another repo re-reads THAT repo's guard.policy.json from its
# origin and decides with it, failing CLOSED when it cannot be read. The globals
# are reassigned rather than shadowed on purpose: this process exits right after,
# and threading four values through three helpers would be the kind of change
# that quietly stops covering one of them.
check_pr_merge() {
  local pr="$1" repo="${2:-}" refs base head sess tsv
  sess="$(session_repo)"
  # No `--repo`, or it names the session's own repo -> the policy already loaded
  # is the right one. Anything else — including a cwd that is not a repo, where
  # `sess` is empty and "who am I" has no answer — goes and reads the target's.
  if [ -n "$repo" ] && [ "$repo" != "$sess" ]; then
    tsv="$(target_policy_tsv "$repo")"
    if [ -z "$tsv" ]; then
      deny "gh pr merge targets ${repo}, whose scripts/hooks/guard.policy.json could not be read, so the policy that governs it is unknown" \
        "check the repo name, or merge from a session rooted in that repo (a repo with no vendored policy reserves its merges to a human)"
    fi
    AGENT_MAY_MERGE=false
    PROTECTED_BRANCH=main
    INTEGRATION_BRANCH=""
    LONG_LIVED_BRANCHES=()
    while IFS=$'\t' read -r key val; do
      case "$key" in
        MERGE) AGENT_MAY_MERGE="$val" ;;
        PROTECTED) PROTECTED_BRANCH="$val" ;;
        INTEGRATION) INTEGRATION_BRANCH="$val" ;;
        LONGLIVED) [ -n "$val" ] && LONG_LIVED_BRANCHES+=("$val") ;;
      esac
    done <<<"$tsv"
  fi

  if [ "$AGENT_MAY_MERGE" != "true" ]; then
    deny_human_merge "gh pr merge merges the PR from the CLI$([ -n "$repo" ] && [ "$repo" != "$sess" ] && printf ", and %s reserves its merges to a human" "$repo")"
  fi
  refs="$(pr_refs "$pr" "$repo")"
  base="${refs%%$'\t'*}"
  head="${refs#*$'\t'}"
  if [ "$base" = "$PROTECTED_BRANCH" ] && [ "$head" = "$PROTECTED_BRANCH" ]; then
    # Both fell back to the protected branch: the PR could not be resolved. Say
    # so, instead of reporting a base the guard never actually read — a PR based
    # on the integration branch used to be denied with "base is main", which
    # sends the reader to look at the wrong thing.
    deny "gh pr merge could not resolve PR '${pr}'$([ -n "$repo" ] && printf " in %s" "$repo"), so the base branch is unknown" \
      "pass the PR's repository explicitly (gh pr merge <n> --repo <owner>/<name>) and check the number exists"
  fi
  if [ "$base" = "$PROTECTED_BRANCH" ]; then
    deny_human_merge "gh pr merge would merge a PR whose base is ${PROTECTED_BRANCH} (protected)"
  fi
  if is_long_lived_branch "$head"; then
    deny "gh pr merge would merge a PR whose HEAD branch is '${head}', which is long-lived; with delete_branch_on_merge the merge deletes it" \
      "re-open the PR from a throwaway branch cut from '${head}' (git switch -c chore/back-merge-${head}-a-${base} origin/${head}) and merge that instead"
  fi
  return 0
}
check_gh() {
  # Locate the first two subcommands, skipping global flags. Also capture the
  # first positional after `pr merge` (the PR number/URL/branch), for the
  # base-branch check.
  local i=1 sub1="" sub2="" a merge_arg="" repo_arg=""
  while [ "$i" -lt "${#tok[@]}" ]; do
    a="${tok[i]}"
    case "$a" in
      -R | --repo)
        # Captured, not just skipped: pr_base_branch needs it to look the PR up
        # in the RIGHT repo. See the note there.
        repo_arg="${tok[i + 1]:-}"
        i=$((i + 2))
        continue
        ;;
      -R=* | --repo=*)
        repo_arg="${a#*=}"
        i=$((i + 1))
        continue
        ;;
      --hostname)
        i=$((i + 2))
        continue
        ;;
      -*)
        i=$((i + 1))
        continue
        ;;
    esac
    if [ -z "$sub1" ]; then
      sub1="$a"
    elif [ -z "$sub2" ]; then
      sub2="$a"
    elif [ -z "$merge_arg" ]; then
      # Do NOT stop here. This used to `break`, and `--repo` almost always comes
      # AFTER the PR number (`gh pr merge 123 --repo owner/name --squash`), so
      # the flag was never reached and repo_arg stayed empty. Keep scanning to
      # the end; only the FIRST positional after `pr merge` is the PR.
      merge_arg="$a"
    fi
    i=$((i + 1))
  done

  if [ "$sub1" = "pr" ] && [ "$sub2" = "merge" ]; then
    check_pr_merge "$merge_arg" "$repo_arg"
  fi

  # `gh pr create` without a label. The label is what the release gate reads, and putting it in a
  # SECOND command run afterwards is how it goes missing: measured 2026-08-14, five of ~20 PRs
  # opened in one session shipped unlabelled, each one red on its repo's require-semver-label gate.
  #
  # This denies the shape that loses the label, not the tool: `gh pr create --label X` passes
  # straight through. `pr-create.sh` is the comfortable path — it also checks the label EXISTS
  # (gh accepts a non-existent one, warns on stdout and still exits 0) and re-reads the PR
  # afterwards to prove it stuck.
  if [ "$sub1" = "pr" ] && [ "$sub2" = "create" ]; then
    local has_label=0
    for a in "${tok[@]:1}"; do
      case "$a" in
        --label | --label=* | -l) has_label=1 ;;
      esac
    done
    if [ "$has_label" -eq 0 ]; then
      deny "gh pr create without --label leaves the release gate's label to a second command, which is how it gets forgotten" \
        "pass it here (gh pr create --label semver:<x> ...) or use core-dev's pr-create.sh, which also verifies the label actually landed"
    fi
  fi

  # Raw API merges are never the sanctioned path (pr-score uses `gh pr merge`),
  # so they are denied regardless of agent_may_merge.
  if [ "$sub1" = "api" ]; then
    for a in "${tok[@]:1}"; do
      case "$a" in
        */merge | */merges)
          deny_human_merge "gh api on a merge endpoint is equivalent to merging the PR"
          ;;
      esac
    done
    # The mutation may be split across segments by tokenization; search the
    # whole command (SEGMENTS is global).
    if [[ "$SEGMENTS" == *mergePullRequest* ]]; then
      deny_human_merge "gh api graphql with mergePullRequest merges the PR"
    fi
  fi
  return 0
}

check_env_dump() {
  local a
  for a in "${tok[@]:1}"; do
    if is_env_file "$a"; then
      deny "dumping the contents of '${a}' would expose credentials in the transcript" \
        "use .env.example as a template or ask the user for the specific value"
    fi
  done
  return 0
}

check_generated_write() {
  local cmd="$1" a tree
  [ "${#GEN_TREES[@]}" -eq 0 ] && return 0
  case "$cmd" in
    sed)
      # sed only writes with -i/--in-place; without it, it is read-only.
      local inplace=0
      for a in "${tok[@]:1}"; do
        case "$a" in
          -i* | --in-place*) inplace=1 ;;
        esac
      done
      if [ "$inplace" -eq 0 ]; then return 0; fi
      for a in "${tok[@]:1}"; do
        for tree in "${GEN_TREES[@]}"; do
          if [[ "$a" == *"$tree"* ]]; then deny_generated "$tree" "$a"; fi
        done
      done
      ;;
    rm | tee)
      for a in "${tok[@]:1}"; do
        for tree in "${GEN_TREES[@]}"; do
          if [[ "$a" == *"$tree"* ]]; then deny_generated "$tree" "$a"; fi
        done
      done
      ;;
    cp | mv)
      # Only the destination (last positional argument) counts: copying FROM
      # the generated tree to elsewhere is legitimate.
      local last=""
      for a in "${tok[@]:1}"; do
        case "$a" in
          -*) ;;
          *) last="$a" ;;
        esac
      done
      for tree in "${GEN_TREES[@]}"; do
        if [[ "$last" == *"$tree"* ]]; then deny_generated "$tree" "$last"; fi
      done
      ;;
  esac
  return 0
}

# Egress restricted to the policy allow-list (default: localhost). Universal.
check_egress() {
  local a url host allowed h
  for a in "${tok[@]:1}"; do
    # Only URLs with an explicit scheme (http://, https://, ftp://…) are
    # evaluated: detecting bare hosts (curl example.com) is ambiguous vs file
    # names and would give false positives — documented limitation.
    if [[ "$a" =~ ^[A-Za-z][A-Za-z0-9+.-]*:// ]]; then
      url="$a"
      host="${url#*://}"
      host="${host%%/*}"
      host="${host##*@}"
      if [[ "$host" == \[* ]]; then
        # Bracketed IPv6: [::1]:3001
        host="${host#\[}"
        host="${host%%\]*}"
      else
        host="${host%%:*}"
      fi
      [ -z "$host" ] && continue
      allowed=0
      for h in "${EGRESS_ALLOW[@]}"; do
        if [ "$host" = "$h" ]; then allowed=1; break; fi
      done
      if [ "$allowed" -eq 0 ]; then
        deny "curl/wget toward '${host}': network egress is restricted to the allow-list" \
          "point it at localhost/127.0.0.1/[::1] or ask the user to fetch the resource"
      fi
    fi
  done
  return 0
}

# --- Segment analysis -------------------------------------------------------

check_segment() {
  local seg="$1"
  local -a raw=() tok=()
  local t

  # Simple whitespace tokenization: quotes are NOT interpreted (tripwire); they
  # are only stripped from the ends of each token.
  read -r -a raw <<<"$seg" || true
  if [ "${#raw[@]}" -eq 0 ]; then return 0; fi
  for t in "${raw[@]}"; do
    t="${t#\"}"
    t="${t%\"}"
    t="${t#\'}"
    t="${t%\'}"
    tok+=("$t")
  done

  # Skip inert prefixes: env assignments, wrappers and shell keywords (do/then/…
  # appear as segment heads when loops/conditionals are split by ';').
  local start=0
  while [ "$start" -lt "${#tok[@]}" ]; do
    t="${tok[start]}"
    if [[ "$t" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      start=$((start + 1))
      continue
    fi
    case "$t" in
      sudo | command | exec | nohup | time | env | do | then | else | elif | if | while | until)
        start=$((start + 1))
        continue
        ;;
    esac
    break
  done
  if [ "$start" -ge "${#tok[@]}" ]; then return 0; fi
  tok=("${tok[@]:start}")

  local cmd0="${tok[0]}"
  cmd0="${cmd0##*/}" # in case it is invoked with an absolute path (/usr/bin/curl)

  # Redirections into a generated tree: apply to any command.
  check_generated_redirect "$seg"

  case "$cmd0" in
    git) check_git ;;
    gh) check_gh ;;
    curl | wget) check_egress ;;
  esac

  case "$cmd0" in
    cat | head | tail | less | more | grep | sed | awk | strings | base64 | xxd | od | tee)
      check_env_dump
      ;;
  esac

  case "$cmd0" in
    cp | mv | rm | tee | sed) check_generated_write "$cmd0" ;;
  esac

  return 0
}

# --- Command extraction from the harness JSON -------------------------------
# node parses the JSON (no jq: not guaranteed on the machine; node >= 24 is a
# repo requirement), strips heredoc bodies (literal data, e.g. commit messages
# — analyzing them would give false positives) and splits the command into
# segments by shell operators, one per line.

read -r -d '' EXTRACT_JS <<'JS' || true
const fs = require("fs");
let raw = "";
try {
  raw = fs.readFileSync(0, "utf8");
} catch (e) {
  process.exit(0);
}
let data;
try {
  data = JSON.parse(raw);
} catch (e) {
  process.exit(0);
}
const cmd = data && data.tool_input ? data.tool_input.command : undefined;
if (typeof cmd !== "string" || cmd.trim() === "") process.exit(0);

// Strips heredoc bodies (<<EOF ... EOF): they are data, not commands. The
// lookaround avoids confusing here-strings (<<<) with heredocs.
function stripHeredocs(src) {
  const opRe = /(?<!<)<<(?!<)-?\s*(["']?)([A-Za-z_][A-Za-z0-9_]*)\1/;
  let out = "";
  let rest = src;
  for (;;) {
    const m = opRe.exec(rest);
    if (!m) {
      out += rest;
      break;
    }
    const eol = rest.indexOf("\n", m.index + m[0].length);
    if (eol === -1) {
      out += rest;
      break;
    }
    out += rest.slice(0, eol + 1);
    const tail = rest.slice(eol + 1);
    const endRe = new RegExp("^\\t*" + m[2] + "[ \\t]*$", "m");
    const em = endRe.exec(tail);
    if (!em) break; // unterminated heredoc: drop the rest (conservative)
    rest = tail.slice(em.index + em[0].length);
  }
  return out;
}

// Split into segments on shell operators — but QUOTE-AWARE, which the previous
// regex split was not. It cut on `(` and `)` everywhere, including inside a quoted
// string, and that broke the rule it was feeding: this repo's own convention makes
// every PR title `type(scope): ...`, so
//
//     gh pr create --title "chore(guard): x" --label semver:patch
//
// was cut after `--title "chore`, and the segment holding `pr create` no longer saw
// the `--label` that came later. The guard denied a command that DID carry the label.
// Measured 2026-08-19: four independent sessions hit it within minutes of the rule
// shipping, each one working around it by reordering flags. A guard whose false
// positive is routine gets routed around, and then it is not a guard.
//
// Rules, mirroring the shell:
//   - inside '...'  nothing is special until the closing quote;
//   - inside "..."  operators are literal, but `$(` and a backtick still open a
//     command substitution, so those DO split — that is real code and must be seen;
//   - outside quotes, everything splits as before.
// Coverage is ADDITIVE, never traded away: the quoted span is emitted as its own extra
// segment too. So `bash -c "git push --force …"` is still analyzed — the string really
// does get executed — while `gh pr create --title "chore(x): y" --label z` keeps its
// label in the same segment as `pr create`. Nothing that was detected before stops being
// detected; what stops is cutting a command in half at a quoted parenthesis.
function splitSegments(str) {
  const out = [];
  const inner = [];
  let cur = "";
  let buf = "";     // text inside the current quoted span
  let q = null;     // null | "'" | '"'
  const push = () => { const t = cur.trim(); if (t) out.push(t); cur = ""; };
  const closeQuote = () => { const t = buf.trim(); if (t) inner.push(t); buf = ""; q = null; };
  for (let i = 0; i < str.length; i++) {
    const c = str[i];
    const next = str[i + 1];
    // The quote characters themselves stay in the segment: downstream rules match on
    // the segment text, so rewriting it here would be a second, invisible change.
    if (q === "'") { cur += c; if (c === "'") closeQuote(); else buf += c; continue; }
    if (q === '"') {
      // A backslash-newline is a LINE CONTINUATION: bash removes it before the word ever
      // exists. Keeping it turned one command into two segments (see the unquoted branch).
      if (c === "\\" && next === "\n") { cur += " "; buf += " "; i++; continue; }
      if (c === "\\" && next) { cur += c + next; buf += c + next; i++; continue; }
      if (c === '"') { cur += c; closeQuote(); continue; }
      if (c === "$" && next === "(") { push(); i++; continue; }
      if (c === "`") { push(); continue; }
      cur += c; buf += c;
      continue;
    }
    // A backslash-newline is a line continuation, not two characters: bash joins the lines
    // before parsing. The guard used to keep the pair verbatim, so the segment carried a raw
    // newline into the shell's line-based read loop below and got TORN IN HALF. Measured
    // 2026-08-21: `gh pr create --repo r --head b \\<newline>  --label semver:none ...` was
    // denied for "without --label", because the first half of the torn segment genuinely had
    // no --label in it. Every rule that requires a flag to be PRESENT somewhere in the command
    // has the same hole, in both directions: a false deny here, a missed deny elsewhere.
    if (c === "\\" && next === "\n") { cur += " "; i++; continue; }
    if (c === "\\" && next) { cur += c + next; i++; continue; }
    if (c === "'" || c === '"') { q = c; cur += c; buf = ""; continue; }
    if (c === "$" && next === "(") { push(); i++; continue; }
    if (c === "`") { push(); continue; }
    if (c === "|" || c === "&") {
      if (next === c) i++; // || and && are one operator, not two
      push();
      continue;
    }
    if (c === ";" || c === "\n" || c === "(" || c === ")") { push(); continue; }
    cur += c;
  }
  push();
  // An unterminated quote leaves text in buf; analyze it rather than drop it.
  if (buf.trim()) inner.push(buf.trim());
  // The quoted spans are re-split with the same rules, so an operator inside a quoted
  // command still separates the commands it joins.
  for (const t of inner) {
    if (t === str.trim()) continue; // no progress: would recurse forever
    for (const s of splitSegments(t)) out.push(s);
  }
  return out;
}

for (const seg of splitSegments(stripHeredocs(cmd))) {
  // One segment, one line. The shell reads this back with `while read -r`, so a segment
  // carrying a literal newline (only possible from inside a quoted span) would arrive as two
  // segments and each half would be matched on its own. Collapsing to a space keeps the
  // segment whole; the quoted span is still re-split on its own by the `inner` pass above, so
  // nothing that used to be caught stops being caught.
  process.stdout.write(seg.replace(/\n/g, " ") + "\n");
}
JS

SEGMENTS="$(node -e "$EXTRACT_JS" 2>/dev/null || true)"
if [ -z "$SEGMENTS" ]; then
  # Fail-open: no extractable command means nothing to evaluate (see header).
  exit 0
fi

while IFS= read -r SEGMENT; do
  check_segment "$SEGMENT"
done <<<"$SEGMENTS"

exit 0
