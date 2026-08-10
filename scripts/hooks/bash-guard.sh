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
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Policy (repo-specific parameters; strict defaults if absent) ------------
# Read once via node into shell-safe variables. Missing/invalid file → strict
# defaults: no generated trees, agent may not merge, main protected, egress
# restricted to localhost. Strict-by-default: an absent policy never weakens.
POLICY_FILE="${BASH_GUARD_POLICY:-$HERE/guard.policy.json}"
POLICY_TSV="$(node -e '
const fs = require("fs");
let p = {};
try { p = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch (e) {}
const trees = Array.isArray(p.generated_trees) ? p.generated_trees : [];
const regen = typeof p.generated_regen_hint === "string" ? p.generated_regen_hint : "";
const merge = p.agent_may_merge === true ? "true" : "false";
const prot = typeof p.protected_branch === "string" && p.protected_branch ? p.protected_branch : "main";
const integ = typeof p.integration_branch === "string" && p.integration_branch ? p.integration_branch : "";
const egress = Array.isArray(p.egress_allow) && p.egress_allow.length
  ? p.egress_allow : ["localhost", "127.0.0.1", "::1"];
const out = [];
out.push("MERGE\t" + merge);
out.push("PROTECTED\t" + prot);
out.push("INTEGRATION\t" + integ);
out.push("REGEN\t" + regen);
for (const t of trees) if (typeof t === "string" && t) out.push("TREE\t" + t);
for (const h of egress) if (typeof h === "string" && h) out.push("EGRESS\t" + h);
process.stdout.write(out.join("\n") + "\n");
' "$POLICY_FILE" 2>/dev/null || true)"

AGENT_MAY_MERGE=false
PROTECTED_BRANCH=main
INTEGRATION_BRANCH=""
GEN_REGEN_HINT=""
GEN_TREES=()
EGRESS_ALLOW=()
if [ -n "$POLICY_TSV" ]; then
  while IFS=$'\t' read -r key val; do
    case "$key" in
      MERGE) AGENT_MAY_MERGE="$val" ;;
      PROTECTED) PROTECTED_BRANCH="$val" ;;
      INTEGRATION) INTEGRATION_BRANCH="$val" ;;
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

# Resolve a PR's base branch (for `gh pr merge <n>`), so the guard can allow a
# merge into the integration branch while always denying a merge into the
# protected branch. TEST-ONLY override BASH_GUARD_PR_BASE avoids the network
# call. Fails CLOSED: if the base cannot be determined, return the protected
# branch so the merge is denied.
pr_base_branch() {
  local pr="$1"
  if [ -n "${BASH_GUARD_PR_BASE:-}" ]; then
    printf '%s' "$BASH_GUARD_PR_BASE"
    return 0
  fi
  local base
  base="$(gh pr view "$pr" --json baseRefName -q .baseRefName 2>/dev/null || true)"
  if [ -z "$base" ]; then
    printf '%s' "$PROTECTED_BRANCH"
    return 0
  fi
  printf '%s' "$base"
}

# A `gh pr merge` attempt. Merging into the protected branch is always denied
# (human-only, per contract). Merging into the integration branch is allowed
# only when the policy grants agent_may_merge; otherwise denied.
check_pr_merge() {
  local pr="$1" base
  if [ "$AGENT_MAY_MERGE" != "true" ]; then
    deny_human_merge "gh pr merge merges the PR from the CLI"
  fi
  base="$(pr_base_branch "$pr")"
  if [ "$base" = "$PROTECTED_BRANCH" ]; then
    deny_human_merge "gh pr merge would merge a PR whose base is ${PROTECTED_BRANCH} (protected)"
  fi
  return 0
}

check_gh() {
  # Locate the first two subcommands, skipping global flags. Also capture the
  # first positional after `pr merge` (the PR number/URL/branch), for the
  # base-branch check.
  local i=1 sub1="" sub2="" a merge_arg=""
  while [ "$i" -lt "${#tok[@]}" ]; do
    a="${tok[i]}"
    case "$a" in
      -R | --repo | --hostname)
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
    else
      merge_arg="$a"
      break
    fi
    i=$((i + 1))
  done

  if [ "$sub1" = "pr" ] && [ "$sub2" = "merge" ]; then
    check_pr_merge "$merge_arg"
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

let s = stripHeredocs(cmd);
// Command substitutions and subshells are opened as their own segments so that
// what they run inside is analyzed too.
s = s.replace(/\$\(/g, "\n").replace(/`/g, "\n");
for (const seg of s.split(/\|\||&&|;|\||&|\n|\(|\)/)) {
  const t = seg.trim();
  if (t) process.stdout.write(t + "\n");
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
