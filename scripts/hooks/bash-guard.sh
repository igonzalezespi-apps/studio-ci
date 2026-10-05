#!/usr/bin/env bash
# ============================================================================
# bash-guard.sh — PreToolUse guard (matcher: Bash|Monitor|PowerShell) for Claude Code
# ============================================================================
# Canonical source: plugins/core-dev/scripts/hooks/bash-guard.sh of the core-dev plugin; in
# a vendored copy, the .vendor.lock next to this file names the repository and commit.
# This file is VENDORED (committed) into each consuming repo and cabled from its
# settings.json — it is NOT a plugin hook, because ${CLAUDE_PLUGIN_ROOT} does
# not exist inside a git hook and a repo must keep enforcing without the plugin.
# The universal core is identical across repos; everything repo-specific lives
# in guard.policy.json next to this file.
#
# ONE EXCEPTION: the guard's own source repository. There the guard is the code
# being edited, so running the working tree's copy would let a half-edited guard
# or policy decide for the session that is editing it. In that repository alone,
# core-dev's plugin hook (source-guard.sh, next to this file) runs the PUBLISHED
# copy from the plugin cache as `bash-guard.sh --project <dir>`: see "Which
# repository, and which copy of its policy" below. Consumers never pass it.
#
# Harness contract: reads the tool-call JSON from STDIN
#   {"tool_name":"Bash","tool_input":{"command":"..."}, ...}
# and emits a verdict. Every rule reads shell commands, so the hook is wired with matcher
# `Bash|Monitor|PowerShell`, the three tools that run a command the model writes (`tool_input.command`):
# Monitor runs it in the same shell as Bash, and PowerShell (native on Windows, opt-in elsewhere) in
# PowerShell. The guard judges all three as a Bash command: the git, gh and network commands its rules
# look for are written the same in PowerShell, and a reading it cannot make is denied, not let
# through. A Monitor call with a `ws` source has no command and nothing to judge. A matcher of `Bash`
# alone let every Monitor and PowerShell command through unread (found 2026-10-04, #311).
# The one rule that also judges the file tools is `forbidden_paths` (see the policy schema): a
# repository that sets it wires this same script a second time, with matcher
# `Read|Edit|Write|MultiEdit|NotebookEdit|Grep|Glob`. The verdict:
#   - allow → exit 0, no output
#   - deny  → exit 2 + "bash-guard DENY: <reason>. Alternative: <what to do>"
#             on stderr (the harness blocks the command and the agent reads the
#             reason to self-correct instead of retrying blindly)
#
# ⚠️ TRIPWIRE — THIS IS NOT A SECURITY BOUNDARY ⚠️
# A best-effort firewall against agent mistakes, not hermetic: it reads the
# command line it is handed, so anything that hides the real command from a
# simple tokenizer — another interpreter, an indirection, a script written first
# and run afterwards — is NOT guaranteed to be intercepted. The guard is also
# fail-open: if command extraction fails (node absent, malformed JSON), it
# allows — a broken tripwire must not take down the harness. Nothing else lets a
# command through: Claude Code blocks only on exit 2, so any other exit runs the
# command, and so does a hook that runs past the harness's timeout. The guard
# therefore judges in a child process under a supervisor (see the end of this
# file), and a command it cannot read and judge within its own time limit, or one
# it fails on (its reader or itself ending other than allow or deny, out of
# resources, killed), is denied everywhere. The source repository goes further:
# source-guard.sh also turns a missing node into a deny.
#
# Do NOT assume a server-side backstop behind it. Branch protection, rulesets and
# required status checks are per-repository settings that this guard neither reads
# nor guarantees; a CI that merely REPORTS does not stop a merge. Whoever vendors
# this file checks what its own repository enforces — `branches/<ref>/protection`
# and `rulesets` — and, until then, treats an escape here as a real escape.
#
# BASH_GUARD_BRANCH: override of the current branch, TEST-ONLY (bash-guard.test.sh)
# — lets the suite simulate "on main"/"on a PR branch" deterministically. In
# production the branch resolves via `git branch --show-current` (empty in
# detached HEAD or outside a repo → treated as not-main).
# BASH_GUARD_POLICY: override of the policy path, TEST-ONLY. It wins over both
# modes below; source-guard.sh strips every BASH_GUARD_* variable before it runs
# the published guard, so in production it can only come from a test.
# BASH_GUARD_PR_BASE: override of a PR's base branch, TEST-ONLY (avoids a network
# call to gh in the merge-to-integration check).
# BASH_GUARD_PR_HEAD: override of a PR's head branch, TEST-ONLY (same lookup).
# Setting either of the two puts the resolver in test mode; see pr_refs.
# BASH_GUARD_PROJECT_ROOT: override of the repository this guard protects,
# TEST-ONLY (see project_identities).
# BASH_GUARD_OWN_REPO: override of this repository's "owner/name" for the merge
# check, TEST-ONLY (see merge_target).
# BASH_GUARD_HOME: override of the home `~` stands for in forbidden_paths and in a
# `cd ~`, TEST-ONLY.
# BASH_GUARD_SECONDS: override of the guard's time limit, TEST-ONLY (see GUARD_DEADLINE
# and the end of this file).
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Which repository, and which copy of its policy --------------------------
# VENDORED (no arguments; every consumer). The protected repository is the one
# that holds this file, and its policy is guard.policy.json next to it: $HERE is
# <repo>/scripts/hooks, the path the rest of the tooling reads the policy from
# ($CLAUDE_PROJECT_DIR/scripts/hooks/guard.policy.json) whenever the hook runs
# as wired. $CLAUDE_PROJECT_DIR is NOT consulted: it names the session, and a
# session in one repository running another repository's vendored guard must
# get that repository's policy AND identity, never one of each (see
# project_identities and the "production anchor" cases of the suite).
#
# PUBLISHED (`--project <dir>`; only source-guard.sh passes it). The guard runs
# from the plugin cache, outside the repository it protects, and the guard.policy.json
# next to it is the plugin's FIXTURE, not anyone's policy. So:
#   - the protected repository is <dir> (source-guard.sh derives it from
#     $CLAUDE_PROJECT_DIR);
#   - its policy is <dir>'s scripts/hooks/guard.policy.json AS ORIGIN'S DEFAULT
#     BRANCH CARRIES IT — reviewed and merged — and never the working tree's,
#     which the session itself may be editing. Read from the local remote-tracking
#     ref first (`git show`, no network per command), then from the API through
#     target_policy_tsv (the reader a cross-repo `gh pr merge` already uses), and
#     failing both, strict defaults. A local edit of the policy applies once it
#     is merged and fetched, not before.
# A `--project` that is empty or not a directory leaves no repository to call
# ours and no policy to read: every push counts as ours and the defaults apply.
PUBLISHED=0
PUBLISHED_PROJECT=""
case "${1:-}" in
  --project) PUBLISHED=1; PUBLISHED_PROJECT="${2:-}" ;;
  --project=*) PUBLISHED=1; PUBLISHED_PROJECT="${1#--project=}" ;;
esac
# The directory whose repository this guard protects (see project_identities).
if [ "$PUBLISHED" -eq 1 ]; then
  ANCHOR_ROOT="$PUBLISHED_PROJECT"
else
  ANCHOR_ROOT="$HERE"
fi

# --- Policy (repo-specific parameters; strict defaults if absent) ------------
# Read once via node into shell-safe variables. Missing/invalid file → strict
# defaults: no generated trees, agent may not merge, main protected, egress
# restricted to localhost. Strict-by-default: an absent policy never weakens.
# Loaded by load_policy, called once the helpers it needs are defined.
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
const prLabel = p.require_pr_label === false ? "false" : "true";
const prot = typeof p.protected_branch === "string" && p.protected_branch ? p.protected_branch : "main";
const integ = typeof p.integration_branch === "string" && p.integration_branch ? p.integration_branch : "";
const longLived = Array.isArray(p.long_lived_branches) ? p.long_lived_branches : [];
const egress = Array.isArray(p.egress_allow) && p.egress_allow.length
  ? p.egress_allow : ["localhost", "127.0.0.1", "::1"];
const worktree = p.one_worktree_per_task === true ? "true" : "false";
const forbidden = Array.isArray(p.forbidden_paths) ? p.forbidden_paths : [];
const out = [];
out.push("MERGE\t" + merge);
out.push("PRLABEL\t" + prLabel);
out.push("PROTECTED\t" + prot);
out.push("INTEGRATION\t" + integ);
for (const b of longLived) if (typeof b === "string" && b) out.push("LONGLIVED\t" + b);
out.push("REGEN\t" + regen);
for (const t of trees) if (typeof t === "string" && t) out.push("TREE\t" + t);
for (const h of egress) if (typeof h === "string" && h) out.push("EGRESS\t" + h);
out.push("WORKTREE\t" + worktree);
for (const f of forbidden) if (typeof f === "string" && f && !/[\t\n\r]/.test(f)) out.push("FORBID\t" + f);
process.stdout.write(out.join("\n") + "\n");
'

AGENT_MAY_MERGE=false
REQUIRE_PR_LABEL=true
PROTECTED_BRANCH=main
INTEGRATION_BRANCH=""
LONG_LIVED_BRANCHES=()
GEN_REGEN_HINT=""
GEN_TREES=()
EGRESS_ALLOW=()
ONE_WORKTREE_PER_TASK=false
FORBIDDEN_PATHS=()
# Sets the globals above from the policy of the mode in force. A function, called
# right before the segments are checked, only because the published mode needs
# helpers defined further down (published_policy_tsv); the vendored mode reads the
# same file with the same reader as ever.
load_policy() {
  local POLICY_TSV key val
  if [ "$PUBLISHED" -eq 1 ] && [ -z "${BASH_GUARD_POLICY:-}" ]; then
    POLICY_TSV="$(published_policy_tsv "$PUBLISHED_PROJECT")"
  else
    POLICY_TSV="$(node -e "$POLICY_READER" "$POLICY_FILE" 2>/dev/null || true)"
  fi
  if [ -n "$POLICY_TSV" ]; then
    while IFS=$'\t' read -r key val; do
      case "$key" in
        MERGE) AGENT_MAY_MERGE="$val" ;;
        PRLABEL) REQUIRE_PR_LABEL="$val" ;;
        PROTECTED) PROTECTED_BRANCH="$val" ;;
        INTEGRATION) INTEGRATION_BRANCH="$val" ;;
        LONGLIVED) [ -n "$val" ] && LONG_LIVED_BRANCHES+=("$val") ;;
        REGEN) GEN_REGEN_HINT="$val" ;;
        TREE) [ -n "$val" ] && GEN_TREES+=("$val") ;;
        EGRESS) [ -n "$val" ] && EGRESS_ALLOW+=("$val") ;;
        WORKTREE) ONE_WORKTREE_PER_TASK="$val" ;;
        FORBID) [ -n "$val" ] && FORBIDDEN_PATHS+=("$val") ;;
      esac
    done <<<"$POLICY_TSV"
  fi
  # Fallback if the policy provided no egress allow-list (defensive; the node
  # reader already defaults, but never leave the list empty → would allow all).
  if [ "${#EGRESS_ALLOW[@]}" -eq 0 ]; then
    EGRESS_ALLOW=("localhost" "127.0.0.1" "::1")
  fi
  return 0
}

# The repository-selecting global options of the git command being analysed (-C,
# --git-dir, -c ...), set by check_git for its segment. Empty = git's own discovery.
GIT_GLOBALS=()

# A segment judged as what its command word stands for (see cw_read) says so in its deny:
# CW_CONTEXT goes in front of the reason, CW_HINT in front of the alternative.
CW_CONTEXT=""
CW_HINT=""
# The second of this shell's clock (SECONDS) past which judging stops and the command is denied; empty,
# no limit. A hook that runs past the harness's timeout lets the command run, and a command can be
# written to keep the guard busy that long while what it denies waits at the end: every
# `git push --force-with-lease` reads every cd before it, and 100 pairs of `cd <dir>; git push
# --force-with-lease` took 8 s, growing with the square (measured 2026-10-03, closing the second
# verification round of #299: some 900 pairs, 34 KB, run past ten minutes; the smallest hook
# timeout of the fleet is 15 s). Real commands are judged in milliseconds, one in
# 1.2 s at most over the 31 days to that date. Set at the end of this file (GUARD_SECONDS): a
# script that sources these functions sets its own.
GUARD_DEADLINE=""
# Set in the judge the supervisor runs (see the end of this file): $$ is the supervisor, and a judge whose
# supervisor is gone (killed) has nobody to give its verdict to, so it stops.
GUARD_SUPERVISED=0
check_deadline() {
  if [ "$GUARD_SUPERVISED" -eq 1 ] && ! kill -0 "$$" 2>/dev/null; then exit 2; fi
  [ -n "$GUARD_DEADLINE" ] && [ "$SECONDS" -ge "$GUARD_DEADLINE" ] || return 0
  deny "the guard could not judge this command within ${GUARD_DEADLINE} s, and a command it cannot judge is not let through" \
    "split it into shorter commands"
}
deny() {
  if [ -n "$CW_CONTEXT" ]; then
    printf 'bash-guard DENY: %s: %s. Alternative: %s%s\n' "$CW_CONTEXT" "$1" "${CW_HINT:+$CW_HINT; then }" "$2" >&2
    exit 2
  fi
  printf 'bash-guard DENY: %s. Alternative: %s\n' "$1" "$2" >&2
  exit 2
}

current_branch() {
  # The override exists only to make the test suite deterministic.
  if [ -n "${BASH_GUARD_BRANCH:-}" ]; then
    printf '%s' "$BASH_GUARD_BRANCH"
    return 0
  fi
  # With the command's own -C / --git-dir replayed: `git -C <worktree> push origin HEAD`
  # pushes the WORKTREE's branch, not the one checked out where the session stands.
  git ${GIT_GLOBALS[@]+"${GIT_GLOBALS[@]}"} branch --show-current 2>/dev/null || true
}

# git with the repository-selecting environment removed, for questions about a
# FIXED repository (the one this guard protects, a local path) that must not be
# redirected by a GIT_DIR inherited from wherever the hook was launched.
git_clean() {
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE \
    -u GIT_OBJECT_DIRECTORY -u GIT_NAMESPACE git "$@"
}

# words_of <text> [<separators>]: the words of the first line of <text>, split at blanks (or at
# <separators>), in SPLIT_WORDS: what `read -r -a SPLIT_WORDS <<<"<text>"` gives, without the
# here-string. Past 64 KiB bash writes a here-string to a temporary file, and where it cannot (a full
# /tmp) the read fails, leaves the array empty and the segment went unjudged (found 2026-10-03, third
# verification round of #299). No glob is expanded: the split runs with globbing off. The first line
# is not cut with `${1%%$'\n'*}`, which bash matches in time quadratic in the length of the text, nor
# is a quote taken off a word with `${w#\"}` (see check_segment): a word of 200 KB took seconds. A
# fixed array, not the caller's through a nameref (`local -n`), which the bash 3.2 of macOS lacks.
SPLIT_WORDS=()
words_of() {
  local text="$1" IFS=$'\n' noglob=0
  local -a text_lines=()
  case "$-" in *f*) noglob=1 ;; esac
  set -f
  case "$text" in
    $'\n'*) text="" ;;
    *$'\n'*)
      # shellcheck disable=SC2206 # splitting is the point; globbing is off
      text_lines=($text)
      text="${text_lines[0]}"
      ;;
  esac
  IFS="${2-$' \t\n'}"
  # shellcheck disable=SC2206 # splitting is the point; globbing is off
  SPLIT_WORDS=($text)
  [ "$noglob" -eq 1 ] || set +f
  return 0
}

# mapfile_of <text>: the lines of <text> in MAPPED_LINES, empty ones included (the command as written,
# where an empty line can end a heredoc), as `mapfile -t MAPPED_LINES <<<"<text>"` gives them but not
# past 64 KiB through a here-string, for the reason in words_of. A text that fits a pipe is still read
# from a here-string, which bash keeps in one (an older bash writes even that one to /tmp); a longer
# one, through a pipe of its own. The bash 3.2 of macOS has no mapfile: a line at a time there. One it
# cannot read is denied: called as a condition, a failure would not stop the guard.
MAPPED_LINES=()
mapfile_of() {
  local line
  if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    MAPPED_LINES=()
    while IFS= read -r line; do
      MAPPED_LINES+=("$line")
    done < <(printf '%s\n' "$1") && return 0
  elif [ "${#1}" -le 4096 ]; then
    mapfile -t MAPPED_LINES <<<"$1" && return 0
  else
    mapfile -t MAPPED_LINES < <(printf '%s\n' "$1") && return 0
  fi
  deny "the guard could not read this command's parts (no room for a temporary file?), and a command it cannot read is not let through" \
    "free space in /tmp, then run it again"
}
# lines_of <text>: the lines of <text> that are not empty, in SPLIT_LINES, split by the shell itself:
# no here-string (see words_of), and no pipe either, whose child process made every later subshell of
# the guard slower (a third, measured on 60 cd/push pairs). Where an empty line means nothing (the
# extractor's segments, the assignments of cw_assignments) this is the same reading.
SPLIT_LINES=()
lines_of() {
  local IFS=$'\n' noglob=0
  case "$-" in *f*) noglob=1 ;; esac
  set -f
  # shellcheck disable=SC2206 # splitting is the point; globbing is off
  SPLIT_LINES=($1)
  [ "$noglob" -eq 1 ] || set +f
  return 0
}
# segment_lines: the lines of SEGMENTS (the extractor's output) in SEGMENT_LINES, split once for each
# value it takes: several rules read them all.
SEGMENT_LINES=()
SEGMENT_LINES_OF=""
SEGMENT_LINES_SET=0
segment_lines() {
  [ "$SEGMENT_LINES_SET" -eq 1 ] && [ "$SEGMENT_LINES_OF" = "${SEGMENTS:-}" ] && return 0
  lines_of "${SEGMENTS:-}"
  SEGMENT_LINES=(${SPLIT_LINES[@]+"${SPLIT_LINES[@]}"})
  SEGMENT_LINES_OF="${SEGMENTS:-}"
  SEGMENT_LINES_SET=1
}

# bare_text <text>: <text> without quotes and backslashes, in BARE_TEXT: what `${1//[\'\"\\]/}` gives,
# split at those characters and joined, in time linear in its length. The bash 3.2 of macOS takes that
# substitution in quadratic time: a second for every 3 KB, and a real command of 3 KB with four
# `gh api` calls was denied at the time limit (main judged it in 0.2 s).
BARE_TEXT=""
bare_text() {
  # shellcheck disable=SC2141 # the backslash is one of the separators
  local IFS=$'\'"\\' noglob=0
  local -a parts=()
  case "$-" in *f*) noglob=1 ;; esac
  set -f
  # shellcheck disable=SC2206 # splitting is the point; globbing is off
  parts=($1)
  [ "$noglob" -eq 1 ] || set +f
  BARE_TEXT=""
  [ "${#parts[@]}" -eq 0 ] || printf -v BARE_TEXT '%s' "${parts[@]}"
  return 0
}

# base_name <word>: its last path component, in BASE_NAME. Not `${w##*/}`: bash matches that
# pattern in time quadratic in what follows the last `/`, and a 120 KB word took seconds to name.
BASE_NAME=""
base_name() {
  local head
  case "$1" in
    */*)
      head="${1%/*}"
      BASE_NAME="${1:${#head}+1}"
      ;;
    *) BASE_NAME="$1" ;;
  esac
  return 0
}

# shown_subst <text>: the text as a deny shows it, each substitution the extractor masked (see
# EXTRACT_JS) written `$(…)`, in SHOWN. Byte-wise (LC_ALL=C): in a multibyte locale bash replaces
# thousands of them in time quadratic in the length of the text, and a command word of 6,000 took
# seconds (found 2026-10-03, third verification round of #299).
SHOWN=""
shown_subst() {
  local LC_ALL=C
  SHOWN="${1//\$__GUARD_SUBST__/\$(…)}"
  return 0
}

# Is the path a real environment file? A committed TEMPLATE is not: env.example, and every
# .env name whose LAST suffix is .example, .sample or .template (.env.example,
# .env.production.example, .env.local.sample). Only the suffix decides, because it survives
# every expansion: a glob or a brace that ENDS in `.example` can only produce names that end
# in `.example`. Before 2026-09-30 only `.env.example` itself was a template: reading
# `.env.prod.example` with cat/grep/sed was denied as a credential dump while `cp` of the same
# file passed (a partner repository's review of its guard; 2 such denies in the transcripts of the 30 days to
# 2026-09-30), so what the agent learnt was the detour, not the rule.
# Everything else under .env stays a secret: the real files, a backup of a template
# (.env.example.bak), a brace that ends elsewhere (.env.{prod,example}) and an unexpanded
# glob (.env*, .env?) that would cover the real files when executed.
is_env_file() {
  local base
  base_name "$1"
  base="$BASE_NAME"
  case "$base" in
    env.example) return 1 ;;
    # ...unless the name holds an expansion: the shell may split that word, and then a piece
    # need not end in the suffix (`.env.$X.example` with X=' .env ' reads .env). Such a name is
    # judged like any other .env name below, as it was before templates were recognised.
    *'$'* | *'`'*) ;;
    .env*.example | .env*.sample | .env*.template) return 1 ;;
  esac
  case "$base" in
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

# git_word <k>: the shell word that starts at whitespace token k of the segment (tok, with raw
# beside it). A quoted part with blanks spans several tokens and all of them are that one word
# (`-c user.name="A B"`, `-C "/a b"`, `-C /a\ b`): GW_VALUE is the word (its tokens joined by a
# blank), GW_NEXT the token after it. Taking the second half for the subcommand left every git rule
# out, the --force one included (pfx_next does the same for the wrappers in front).
GW_VALUE=""
GW_NEXT=0
git_word() {
  local k="$1"
  GW_VALUE="${tok[k]:-}"
  GW_NEXT=$((k + 1))
  [ "${#raw[@]}" -eq "${#tok[@]}" ] || return 0
  quote_carry "" "${raw[k]:-}"
  while [ -n "$QC" ] && [ "$GW_NEXT" -lt "${#tok[@]}" ]; do
    GW_VALUE+=" ${tok[GW_NEXT]}"
    quote_carry "$QC" "${raw[GW_NEXT]}"
    GW_NEXT=$((GW_NEXT + 1))
  done
  return 0
}

check_git() {
  # Skip git global options (those that take a separate value, in pairs) to
  # locate the real subcommand. `git -c x=y push` obfuscation is not guaranteed
  # (see header), beyond the push configuration check_git_push reads from -c.
  # The ones that decide WHICH repository git works on and where its remotes point
  # are kept verbatim in GIT_GLOBALS, so the push check can replay them and ask git
  # itself instead of re-deriving git's repository discovery by hand.
  local i=1 sub="" opt
  GIT_GLOBALS=()
  while [ "$i" -lt "${#tok[@]}" ]; do
    opt="${tok[i]}"
    case "$opt" in
      -c | -C | --git-dir | --work-tree | --config-env)
        git_word $((i + 1))
        GIT_GLOBALS+=("$opt" "$GW_VALUE")
        i=$GW_NEXT
        ;;
      # Their value can also be the next word: taking it for the subcommand left `git
      # --attr-source HEAD push --force` judged by no rule.
      --namespace | --exec-path | --attr-source)
        git_word $((i + 1))
        i=$GW_NEXT
        ;;
      --git-dir=* | --work-tree=* | --config-env=* | --bare)
        git_word "$i"
        GIT_GLOBALS+=("$GW_VALUE")
        i=$GW_NEXT
        ;;
      -*)
        git_word "$i"
        i=$GW_NEXT
        ;;
      *)
        sub="${tok[i]}"
        i=$((i + 1))
        break
        ;;
    esac
  done
  case "$sub" in
    # send-pack is the plumbing under push: the same <repository> [<refspec>...], --force,
    # --all and --mirror, and a refspec with `+` or an empty source forces or deletes alike.
    push | send-pack) check_git_push "$i" ;;
    commit) check_git_commit ;;
    merge) check_git_merge ;;
    branch) check_git_branch "$i" ;;
    update-ref) check_git_update_ref "$i" ;;
    switch | checkout) check_git_switch "$sub" "$i" ;;
  esac
  return 0
}

# --- Where does a push go? ---------------------------------------------------
# PROTECTED_BRANCH is the policy of the repository that vendored this guard. A push
# to ANOTHER repository must not inherit it: that repository's main is not ours,
# and its own flow may well be to push to it. Measured 2026-08-03: a one-line fix
# in a repository whose flow IS pushing to main was denied from a session rooted
# in a consumer, and had to detour through a branch, a PR and a human merge. A
# guard that fires where it has no business teaches its users to route around it.
#
# The destination is decided by the REMOTE the push reaches, never by a path.
# Paths lie in both directions: a worktree or a second clone of this repository
# has another top-level directory and pushes to the very same remote, and a
# `git push <url-of-this-repo>` run from anywhere lands here too.
#
# FAIL-CLOSED: a push counts as foreign only when EVERY destination resolves,
# unambiguously, to a remote that is not one of ours. Anything else — the command
# moves git on the way (`cd`, `pushd`, `env -C`, GIT_DIR=...), the remote does not
# resolve, a URL is not recognisable, the guard cannot tell which repository it
# protects — keeps the protected-branch rule on.

# Does the command move git somewhere the guard cannot follow? Segments are analysed
# one at a time, and git is asked from the hook's own directory: the session's
# CURRENT directory, which follows every `cd` the agent makes (measured 2026-09-14:
# with the session standing in another checkout, `git push origin HEAD` resolved
# HEAD there), not the one a `cd` earlier in the same command leaves behind. So in
# `cd <x> && git push ...` the push would be resolved against the wrong repository,
# in one direction or the other. Rather than guess, any relocation anywhere in the
# command disables the foreign-repository exemption. Deliberately broad: a false
# match only keeps a deny the command would have got anyway.
command_relocates() {
  local line
  local re_cd='(^|[[:space:]])(cd|pushd|popd)([[:space:]]|$)'
  # GIT_DIR & co. move git; GH_REPO moves gh (see pr_label_waived).
  local re_env='(^|[[:space:]])(GIT_[A-Z_]+|GH_REPO)='
  # A wrapper that runs its command in another directory: env -C, sudo -D, nsenter/unshare -w.
  local re_chdir='(^|[[:space:]])(--chdir|--wd|env([[:space:]]+-[^[:space:]]*)*[[:space:]]+-[A-Za-z]*C|sudo([[:space:]]+-[^[:space:]]*)*[[:space:]]+-[A-Za-z]*D|(nsenter|unshare)([[:space:]]+-[^[:space:]]*)*[[:space:]]+-[A-Za-z]*w)([=[:space:]]|$)'
  segment_lines
  for line in ${SEGMENT_LINES[@]+"${SEGMENT_LINES[@]}"}; do
    [[ "$line" =~ $re_cd ]] && return 0
    [[ "$line" =~ $re_env ]] && return 0
    [[ "$line" =~ $re_chdir ]] && return 0
  done
  return 1
}

# One spelling for every way of writing the same remote, so two can be compared.
# The host is dropped on purpose: an ssh alias (`Host gh` → github.com) reaches the
# same repository under another host name, while the path cannot be aliased, so
#   https://github.com/Owner/Name.git   git@github.com:owner/name
#   ssh://git@github.com:22/owner/name  gh:owner/name           → owner/name
# (the same "owner/name" merge_target compares). An absolute local path, or a
# file:// URL, becomes "local:<its git common dir>" when it is a repository —
# shared by all its worktrees. Anything else prints NOTHING, which the caller must
# read as "unknown", never as "some other repository".
remote_identity() {
  local u="$1" host="" path="" dir=""
  case "$u" in
    file://*) u="${u#file://}" ;;
  esac
  case "$u" in
    /*)
      dir="$(cd "$u" 2>/dev/null && cd "$(git_clean rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)" || return 0
      [ -n "$dir" ] && printf 'local:%s' "$dir"
      return 0
      ;;
    *://*)
      u="${u#*://}"
      host="${u%%/*}"
      [ "$host" != "$u" ] || return 0
      path="${u#*/}"
      ;;
    *:*)
      # scp syntax [user@]host:path. A colon AFTER a slash is a relative path.
      host="${u%%:*}"
      path="${u#*:}"
      case "$host" in */*) return 0 ;; esac
      ;;
    *) return 0 ;;
  esac
  [ -n "$host" ] || return 0
  while [ "${path#/}" != "$path" ]; do path="${path#/}"; done
  path="${path%/}"
  path="${path%.git}"
  path="${path%/}"
  [ -n "$path" ] || return 0
  printf '%s' "$path" | tr '[:upper:]' '[:lower:]'
}

# Every identity of the repository this guard protects: the one that holds the guard
# itself. The guard is vendored INTO the repository whose policy it enforces, so
# $HERE is always inside it (worktrees included) — unlike the cwd, which follows the
# agent around, or $CLAUDE_PROJECT_DIR, which names the session and not the owner
# of the policy loaded above. Every remote counts, fetch and push URLs alike: when
# in doubt the rule stays on, and a remote of ours is a doubt.
# The PUBLISHED guard (`--project <dir>`) lives in the plugin cache, outside any
# repository, so there the anchor is <dir> — the repository whose policy it loaded.
# An empty anchor is refused before git sees it: `git -C ""` is the cwd, which
# would make whatever repository the agent stands in "ours".
# TEST-ONLY override: BASH_GUARD_PROJECT_ROOT.
project_identities() {
  local root="${BASH_GUARD_PROJECT_ROOT:-$ANCHOR_ROOT}" remotes="" urls="" r u
  [ -n "$root" ] && [ -d "$root" ] || return 0
  git_clean -C "$root" rev-parse --git-dir >/dev/null 2>&1 || return 0
  remote_identity "$(cd "$root" 2>/dev/null && pwd -P)"
  printf '\n'
  remotes="$(git_clean -C "$root" remote 2>/dev/null)" || remotes=""
  for r in $remotes; do
    urls+="$(git_clean -C "$root" remote get-url --all "$r" 2>/dev/null)"$'\n'
    urls+="$(git_clean -C "$root" remote get-url --push --all "$r" 2>/dev/null)"$'\n'
  done
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    remote_identity "$u"
    printf '\n'
  done <<<"$urls"
  return 0
}

# The URL(s) a push reaches, asked of git with the command's own -C / --git-dir / -c
# replayed: repository discovery, insteadOf rewriting and a pushurl that differs from
# the url are git's answer, not a re-derivation. With no remote named, git picks one
# from its config (pushRemote, pushDefault, the branch's remote, origin); every remote
# of the repository stands in for it. Returns 1 when the destination does not resolve.
push_destination_urls() {
  local remote="$1" remotes="" urls="" out="" r
  if [ -z "$remote" ]; then
    remotes="$(git ${GIT_GLOBALS[@]+"${GIT_GLOBALS[@]}"} remote 2>/dev/null)" || return 1
    [ -n "$remotes" ] || return 1
    for r in $remotes; do
      out="$(git ${GIT_GLOBALS[@]+"${GIT_GLOBALS[@]}"} remote get-url --push --all "$r" 2>/dev/null)" || return 1
      urls+="$out"$'\n'
    done
  elif out="$(git ${GIT_GLOBALS[@]+"${GIT_GLOBALS[@]}"} remote get-url --push --all "$remote" 2>/dev/null)"; then
    urls="$out"
  else
    # Not a configured remote: a URL or a path, after git's insteadOf rewriting.
    out="$(git ${GIT_GLOBALS[@]+"${GIT_GLOBALS[@]}"} ls-remote --get-url "$remote" 2>/dev/null)" || return 1
    urls="$out"
  fi
  printf '%s\n' "$urls"
}

# identity_in <identity> <newline-separated identities>
identity_in() {
  local x
  while IFS= read -r x; do
    [ -n "$x" ] && [ "$x" = "$1" ] && return 0
  done <<<"$2"
  return 1
}

# Is this push aimed at the repository that vendored this guard? True (0) unless it
# is PROVEN foreign — see the fail-closed paragraph above. When it returns 1 it leaves
# the foreign destinations, one identity per line, in PUSH_FOREIGN_IDS.
PUSH_FOREIGN_IDS=""
push_targets_this_repo() {
  local remote="$1" ids="" dests="" u d foreign=0
  PUSH_FOREIGN_IDS=""
  command_relocates && return 0
  ids="$(project_identities)" || ids=""
  [ -n "${ids//$'\n'/}" ] || return 0
  dests="$(push_destination_urls "$remote")" || return 0
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    d="$(remote_identity "$u")" || d=""
    [ -n "$d" ] || return 0
    identity_in "$d" "$ids" && return 0
    identity_in "$d" "$PUSH_FOREIGN_IDS" || PUSH_FOREIGN_IDS+="$d"$'\n'
    foreign=1
  done <<<"$dests"
  [ "$foreign" -eq 1 ] || return 0
  return 1
}

# The protected branch of a FOREIGN push destination, by ITS OWN policy — not ours, which
# is not in charge there, and not "none", which let a session rooted in one consumer push
# straight to another consumer's main. Prints the branch; prints nothing when the destination
# provably vendors no policy (then pushing to its main may well be its flow: the case that
# made foreign pushes exempt in the first place, 2026-08-03); prints the strict default
# `main` when the policy exists but cannot be read, or cannot be looked for.
#   owner/name   the API, as a cross-repository merge reads it (api_policy_tsv: 404 = none).
#   local:<dir>  that repository's own HEAD commit (committed, never a working tree).
destination_protected_branch() {
  local id="$1" tsv="" rc=0 tmp key val prot="main"
  case "$id" in
    local:*)
      if git_clean --git-dir="${id#local:}" cat-file -e HEAD:scripts/hooks/guard.policy.json 2>/dev/null; then
        tmp="$(mktemp 2>/dev/null)" || { printf 'main'; return 0; }
        git_clean --git-dir="${id#local:}" show HEAD:scripts/hooks/guard.policy.json >"$tmp" 2>/dev/null || true
        tsv="$(policy_tsv_from_file "$tmp")"
        rm -f "$tmp"
      else
        # No commit yet, or a HEAD without the file: no policy. A git that cannot even open
        # the directory is not proof of that.
        git_clean --git-dir="${id#local:}" rev-parse --git-dir >/dev/null 2>&1 || printf 'main'
        return 0
      fi
      ;;
    */*)
      tsv="$(api_policy_tsv "$id")" || rc=$?
      [ "$rc" -eq 3 ] && return 0
      ;;
  esac
  while IFS=$'\t' read -r key val; do
    [ "$key" = PROTECTED ] && [ -n "$val" ] && prot="$val"
  done <<<"$tsv"
  printf '%s' "$prot"
}

# May this `gh pr create` go without --label? Only when the policy of the repository the PR
# LANDS IN says `require_pr_label: false`: the label is that repository's release gate, so the
# waiver is that repository's to give. Which repository that is, is merge_target's answer — the
# same one a merge gets, with the same fail-closed shape and the opposite default:
#   this repository   -> the policy loaded at the top of this file;
#   another one       -> ITS guard.policy.json, read from its origin like a merge reads it. Until
#                        2026-09-30 a --repo naming another repository kept the label required no
#                        matter what that repository said, so a session rooted in one consumer
#                        could not open a PR in a repository that does not read labels without a
#                        deny and a retry;
#   cannot tell       -> required (a relocation in the command, a --repo that does not parse, a
#                        cwd whose remotes are not all ours, a --repo or an option the shell
#                        fills in later: $2 = 1).
# A policy that cannot be read keeps it required too: not knowing is never a waiver.
pr_label_waived() {
  local repo="$1" unknown="${2:-0}" target="" rc=0 tsv
  [ "$unknown" = 1 ] && return 1
  target="$(merge_target "$repo")" || rc=$?
  case "$rc" in
    0) [ "$REQUIRE_PR_LABEL" = "false" ] ;;
    1)
      tsv="$(target_policy_tsv "$target")"
      [ -n "$tsv" ] || return 1
      identity_in $'PRLABEL\tfalse' "$tsv"
      ;;
    *) return 1 ;;
  esac
}

# Does `--<given>` name the long option `--<full>`? git takes any unambiguous prefix of a long
# option (`--del` is --delete). A prefix two options share makes git refuse the push, so counting
# it as either one costs nothing.
push_long_is() {
  [ -n "$1" ] && [ "${2#"$1"}" != "$2" ]
}

# push_dest_branch <destination ref as written>: the branch it names, in PUSH_BRANCH. git resolves
# `heads/<b>` to refs/heads/<b> too.
PUSH_BRANCH=""
push_dest_branch() {
  PUSH_BRANCH="$1"
  case "$PUSH_BRANCH" in
    refs/heads/*) PUSH_BRANCH="${PUSH_BRANCH#refs/heads/}" ;;
    heads/*) PUSH_BRANCH="${PUSH_BRANCH#heads/}" ;;
  esac
  return 0
}

# Does the destination pattern of a refspec (`refs/heads/*`, `*`) match a long-lived branch?
push_pattern_reaches_long_lived() {
  local pat="$1" b
  long_lived_names
  for b in "${LONG_LIVED_NAMES[@]}"; do
    # shellcheck disable=SC2053 # the right-hand side is the refspec's pattern, matched as one
    if [[ "refs/heads/$b" == $pat || "heads/$b" == $pat || "$b" == $pat ]]; then
      return 0
    fi
  done
  return 1
}

# The branch HEAD is where this git command runs: the session's directory moved by the command's
# own cd/pushd/popd and -C (command_git_dir), not the directory the hook happens to stand in.
# Nothing when that directory cannot be told. TEST-ONLY override: BASH_GUARD_BRANCH.
push_head_branch() {
  if [ -n "${BASH_GUARD_BRANCH:-}" ]; then
    printf '%s' "$BASH_GUARD_BRANCH"
    return 0
  fi
  command_git_dir || return 0
  git_clean -C "$CMD_GIT_DIR" branch --show-current 2>/dev/null || true
}

check_git_push() {
  local i="$1"
  local force=0 noverify=0 lease=0 del=0 a o k repo_opt=""
  local -a positional=()
  while [ "$i" -lt "${#tok[@]}" ]; do
    a="${tok[i]}"
    i=$((i + 1))
    case "$a" in
      # --repo=<repository> stands for the <repository> argument when there is none.
      --repo)
        repo_opt="${tok[i]:-}"
        i=$((i + 1))
        ;;
      --repo=*) repo_opt="${a#--repo=}" ;;
      # Push flags with a value in a separate token
      -o | --push-option | --receive-pack | --exec) i=$((i + 1)) ;;
      --no-force-with-lease) lease=0 ;;
      --?*)
        o="${a#--}"
        o="${o%%=*}"
        if push_long_is "$o" force; then
          force=1
        elif push_long_is "$o" force-with-lease; then
          # Allowed toward the agent's own branches; judged per destination below.
          lease=1
        elif push_long_is "$o" no-verify; then
          noverify=1
        elif push_long_is "$o" delete; then
          del=1
        elif push_long_is "$o" all || push_long_is "$o" mirror || push_long_is "$o" branches; then
          deny "git push ${a} pushes every branch, including ${PROTECTED_BRANCH}" \
            "push only your PR branch: git push -u origin HEAD"
        elif push_long_is "$o" prune; then
          deny "git push ${a} deletes every remote branch that has no local counterpart, long-lived ones included" \
            "delete a finished branch on the remote by name: git push origin --delete <branch>"
        fi
        ;;
      -?*)
        # A short cluster: -f is --force, -d is --delete, -n is --dry-run (harmless); -o takes the
        # rest of the cluster, or the next word, as its value.
        for ((k = 1; k < ${#a}; k++)); do
          case "${a:k:1}" in
            f) force=1 ;;
            d) del=1 ;;
            o)
              [ "$k" -eq $((${#a} - 1)) ] && i=$((i + 1))
              break
              ;;
          esac
        done
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

  # The refspecs: positional[0] is the remote (name or URL); the rest are <src>:<dst> (without ':'
  # the destination is the ref itself; HEAD, or `@`, is the current branch). Each is judged as the shell
  # hands it to git: quotes ($'…' and $"…" too) and backslashes removed, braces expanded. One the
  # shell fills in later (a variable, a substitution) is not judged. Braces past what brace_words
  # reads (BRACE_MAX words, BRACE_MAX_LEN characters) would leave refspecs unread, `:develop` among
  # them: denied, as check_env_dump does with a .env.
  # The configuration this command sets for itself with -c is read too, never the one stored in the
  # repository: remote.<name>.mirror is --mirror, remote.<name>.push gives the refspecs when the
  # command line has none, and push.default=matching then pushes like `:`.
  local -a refspecs=() cfg_specs=()
  local r w dst kv key val matching=0
  for ((k = 0; k < ${#GIT_GLOBALS[@]}; k++)); do
    [ "${GIT_GLOBALS[k]}" = -c ] || continue
    kv="${GIT_GLOBALS[k + 1]}"
    k=$((k + 1))
    # Lowercased (git's section and key names ignore case) without ${x,,}, which bash 3.2 lacks.
    key="$(printf '%s' "${kv%%=*}" | tr '[:upper:]' '[:lower:]')"
    val="$(printf '%s' "${kv#*=}" | tr '[:upper:]' '[:lower:]')"
    case "$key" in
      remote.*.mirror)
        # Without `=` it is true; only a false value leaves the push alone.
        case "$kv" in *=*) case "$val" in false | no | off | 0 | '') continue ;; esac ;; esac
        deny "git -c ${kv} push mirrors every ref like --mirror, including ${PROTECTED_BRANCH}" \
          "push only your PR branch: git push -u origin HEAD"
        ;;
      remote.*.push) [[ "$kv" == *=?* ]] && cfg_specs+=("${kv#*=}") ;;
      push.default) [ "$val" = matching ] && matching=1 ;;
    esac
  done
  local -a specs_in=()
  if [ "${#positional[@]}" -gt 1 ]; then
    specs_in=("${positional[@]:1}")
  elif [ "${#cfg_specs[@]}" -gt 0 ]; then
    specs_in=("${cfg_specs[@]}")
  elif [ "$matching" -eq 1 ]; then
    deny "git -c push.default=matching push pushes every branch that also exists on the remote, including ${PROTECTED_BRANCH}" \
      "push only your PR branch: git push -u origin HEAD"
  fi
  if [ "${#specs_in[@]}" -gt 0 ]; then
    for r in "${specs_in[@]}"; do
      # What the guard does not expand: the escapes of $'…' (`$'\x64'evelop` is develop) and a
      # sequence in braces (`develo{p..p}`). A ref name never needs either.
      if [[ "$r" == *"\$'"*\\* ]] || [[ "$r" =~ \{[^{},]*\.\.[^{},]*\} ]]; then
        deny "git push ${r}: the guard does not read \$'…' escapes or {a..b} sequences in a refspec" \
          "write the branch name out: git push origin <branch>"
      fi
      w="${r//\$\'/\'}"
      w="${w//\$\"/\"}"
      w="${w//[\"\'\\]/}"
      brace_words "$w"
      if [ "$BRACE_OVER" -eq 1 ] || { [[ "$w" == *'{'*,* ]] && [ "${#w}" -gt "$BRACE_MAX_LEN" ]; }; then
        deny "git push ${r}: its braces expand to more refspecs than the guard reads (${BRACE_MAX} at most)" \
          "push or delete the refspecs in smaller groups"
      fi
      refspecs+=("${BRACE_OUT[@]}")
    done
  fi

  # More rules about the agent, unconditional like the two above:
  #   - a leading `+` forces that ref: it is --force for one ref, and it also overrides
  #     --force-with-lease, so it is denied with or without a lease;
  #   - `:` alone pushes every branch that also exists on the remote, and a pattern every branch
  #     it matches: like --all, when that reaches a long-lived branch;
  #   - deleting a long-lived branch (is_long_lived_branch, the list `git branch -D` uses) on the
  #     remote: `--delete <b>`, `-d <b>`, an empty source (`:<b>`) or the null object id;
  #   - --force-with-lease toward a long-lived branch: the lease is for the agent's own branches.
  for r in ${refspecs[@]+"${refspecs[@]}"}; do
    case "$r" in
      +*)
        deny "git push ${r}: a leading '+' forces that ref like --force, and it overrides --force-with-lease" \
          "drop the '+'; to rewrite your own PR branch after a rebase: git push --force-with-lease origin <your-branch>"
        ;;
      :)
        deny "git push ':' pushes every branch that also exists on the remote, including ${PROTECTED_BRANCH}" \
          "push only your PR branch: git push -u origin HEAD"
        ;;
      *'*'*)
        if push_pattern_reaches_long_lived "${r#*:}"; then
          deny "git push ${r} pushes every branch the pattern matches, long-lived ones included" \
            "push only your PR branch: git push -u origin HEAD"
        fi
        ;;
    esac
    dst=""
    if [ "$del" -eq 1 ]; then
      dst="$r"
    elif [ "${r#:}" != "$r" ]; then
      dst="${r#:}"
    elif [[ "${r%%:*}" =~ ^(0{40}|0{64})$ ]] && [[ "$r" == *:* ]]; then
      # The null object id as the source deletes the destination, like an empty source
      # (measured with git 2.43: `0000…0000:develop` deleted develop).
      dst="${r#*:}"
    fi
    [ -n "$dst" ] || continue
    push_dest_branch "$dst"
    if is_long_lived_branch "$PUSH_BRANCH"; then
      deny "git push deleting '${PUSH_BRANCH}' on the remote: it is a long-lived branch of this flow, and deleting it is not a step of any task" \
        "delete only finished work branches (git push origin --delete <type>/<branch>); deleting a long-lived branch is the user's call"
    fi
  done
  if [ "$lease" -eq 1 ]; then
    local -a lease_dsts=(HEAD)
    if [ "${#refspecs[@]}" -gt 0 ]; then
      lease_dsts=()
      for r in "${refspecs[@]}"; do lease_dsts+=("${r#*:}"); done
    fi
    # The session's directory read here, once: push_head_branch runs in a subshell, which would read it
    # again (a node each time) for every push, and 60 cd/push pairs went near 10 s on a slow runner.
    load_session_cwd
    for dst in "${lease_dsts[@]}"; do
      case "$dst" in HEAD | @) dst="$(push_head_branch)" ;; esac
      push_dest_branch "$dst"
      if is_long_lived_branch "$PUSH_BRANCH"; then
        deny "git push --force-with-lease toward '${PUSH_BRANCH}' rewrites the history of a long-lived branch of this flow" \
          "a long-lived branch only moves through merged PRs; --force-with-lease is for your own PR branch (git push --force-with-lease origin <your-branch>), and rewriting a long-lived one is the user's call"
      fi
    done
  fi

  # Everything below is the protected-branch rule, which is the policy of the repository
  # the push LANDS IN. The checks above stay unconditional: they are rules about the agent,
  # not about any repository.
  #   - this repository (or not provably another one): the policy loaded at the top;
  #   - another repository: ITS policy (destination_protected_branch), so a session rooted
  #     here cannot push to another consumer's main, while a repository that vendors no
  #     policy — whose flow may be pushing to main — keeps no protected branch at all.
  local protected_set="$PROTECTED_BRANCH" whose="" id p
  if ! push_targets_this_repo "${positional[0]:-$repo_opt}"; then
    protected_set=""
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      p="$(destination_protected_branch "$id")"
      [ -n "$p" ] || continue
      protected_set+="$p"$'\n'
      whose+="${whose:+, }${id}"
    done <<<"$PUSH_FOREIGN_IDS"
    [ -n "$protected_set" ] || return 0
  fi

  # Where the protected branch comes from, for the message: a foreign destination's own
  # policy is named, so the reader looks at the right file.
  local by=""
  [ -n "$whose" ] && by=" in ${whose}, by that repository's own guard.policy.json"

  if [ "${#refspecs[@]}" -eq 0 ]; then
    # push with no refspec: with push.default=simple the target is the current branch
    dst="$(current_branch)"
    if [ -n "$dst" ] && identity_in "$dst" "$protected_set"; then
      deny "git push from ${dst} pushes directly to ${dst}${by}" \
        "work on a PR branch (git checkout -b <type>/<issue>-description) and open a PR"
    fi
    return 0
  fi

  for r in "${refspecs[@]}"; do
    r="${r#+}"
    if [[ "$r" == *:* ]]; then
      dst="${r#*:}"
    else
      dst="$r"
    fi
    push_dest_branch "$dst"
    dst="$PUSH_BRANCH"
    if [ -z "$dst" ]; then continue; fi
    # `@` is git's short name for HEAD.
    if [ "$dst" = "HEAD" ] || [ "$dst" = "@" ]; then
      dst="$(current_branch)"
    fi
    if [ -n "$dst" ] && identity_in "$dst" "$protected_set"; then
      # The alternative names the branch, or the worktree with -C: a bare `HEAD`
      # resolves wherever the session happens to stand, so what this message
      # suggests must never contain one.
      deny "push targeting ${dst} is forbidden (${dst} is protected for humans${by})" \
        "push your PR branch by name (git push -u origin <branch>) or from its worktree (git -C <worktree> push -u origin HEAD), and open a PR"
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

# `git branch -d/-D` of a long-lived branch (is_long_lived_branch: the built-in floor, the
# protected and integration branches and `long_lived_branches`). A local copy of one of them that
# is stale is brought up to date, never deleted; deleting it is not a step of any task. Applies in
# every repository: the name is what counts, wherever the command runs. With -r the names are
# remote-tracking (`origin/main`): the part after the remote is judged. A name the shell fills in
# later is not judged, as for a push. Renaming one away (`git branch -m/-M <long-lived> <new>`, or
# `-m <new>` while on it) leaves no branch by that name either: denied too (#306). Renaming another
# branch TO a long-lived name (`git branch -M main` after `git init`) is not touched.
check_git_branch() {
  local i="$1" a del=0 rem=0 mv=0 b
  local -a names=()
  while [ "$i" -lt "${#tok[@]}" ]; do
    a="${tok[i]}"
    i=$((i + 1))
    case "$a" in
      --)
        names+=("${tok[@]:i}")
        break
        ;;
      # git takes any unambiguous prefix of a long option (`--mo` is --move, `--del` --delete).
      --d | --de | --del | --dele | --delet | --delete) del=1 ;;
      --m | --mo | --mov | --move) mv=1 ;;
      --rem | --remo | --remot | --remote | --remotes) rem=1 ;;
      -u) i=$((i + 1)) ;;
      # A long option that takes its value as the next word (`--format X`, `--sort X`): skipped.
      --*=*) ;;
      --*)
        case "$a" in
          --f | --fo | --for | --form | --forma | --format | --so | --sor | --sort | --poi* | --con* | --no-con* | \
            --mer* | --no-mer* | --set-u*) i=$((i + 1)) ;;
        esac
        ;;
      -?*)
        [[ "$a" == *[dD]* ]] && del=1
        [[ "$a" == *[mM]* ]] && mv=1
        [[ "$a" == *r* ]] && rem=1
        ;;
      *) names+=("$a") ;;
    esac
  done
  if [ "$mv" -eq 1 ] && [ "$del" -eq 0 ]; then
    # Counted after the shell's brace expansion: `develop{,-old}` is two names, develop the first.
    local -a exp=()
    local n=0
    for b in ${names[@]+"${names[@]}"}; do
      n=$((n + 1))
      # A name the shell fills in or decodes (`${X:-develop}`, `$'\x64evelop'`, an escaped brace)
      # may be a long-lived branch, unless the text before what is filled in already rules that
      # out (`feature/$TICKET`). The current branch's name printed by git is the current branch.
      # The new name (the last of two) may be anything, unless braces make it more than one
      # (independent review of #311).
      local bare="${b//[\"\']/}"
      case "$bare" in
        '$(git branch --show-current)' | '`git branch --show-current`' | '$(git rev-parse --abbrev-ref HEAD)' | '`git rev-parse --abbrev-ref HEAD`')
          bare="$(current_branch)"
          b="$bare"
          ;;
      esac
      if [[ "$bare" == *[\$\\]* ]] && { [ "$n" -lt "${#names[@]}" ] || [ "${#names[@]}" -gt 2 ] || [[ "${bare//\$\{/}" == *"{"* ]]; }; then
        local pre="${bare%%[\$\\\{]*}" x
        long_lived_names
        for x in "${LONG_LIVED_NAMES[@]}"; do
          if [[ "$x" == "$pre"* ]]; then
            deny "git branch (renaming) a branch whose name the shell fills in (${b}), which may be a long-lived branch of this flow" \
              "name the branch in full (the current one: git branch -m <new name>); renaming a long-lived branch away is the user's call"
          fi
        done
      fi
      brace_words "${b//[\"\']/}"
      [ "$BRACE_OVER" -eq 0 ] || deny_long_lived_delete "git branch (renaming)" "$b"
      exp+=("${BRACE_OUT[@]}")
    done
    names=(${exp[@]+"${exp[@]}"})
    # With more names than git takes, every one is judged rather than guess which it renames.
    case "${#names[@]}" in
      0) return 0 ;;
      1) deny_long_lived_delete "git branch (renaming)" "$(current_branch)" ;;
      2) deny_long_lived_delete "git branch (renaming)" "${names[0]}" ;;
      *) for b in "${names[@]}"; do deny_long_lived_delete "git branch (renaming)" "$b"; done ;;
    esac
    return 0
  fi
  [ "$del" -eq 1 ] || return 0
  for b in ${names[@]+"${names[@]}"}; do
    [ "$rem" -eq 1 ] && b="${b#*/}"
    deny_long_lived_delete "git branch" "$b"
  done
  return 0
}

# The same deletion through the plumbing: `git update-ref -d refs/heads/<branch>`.
check_git_update_ref() {
  local i="$1" a del=0 ref=""
  while [ "$i" -lt "${#tok[@]}" ]; do
    a="${tok[i]}"
    i=$((i + 1))
    case "$a" in
      -d | --delete) del=1 ;;
      -m) i=$((i + 1)) ;;
      -*) ;;
      *)
        [ -n "$ref" ] || ref="$a"
        ;;
    esac
  done
  [ "$del" -eq 1 ] && [ -n "$ref" ] || return 0
  case "$ref" in
    refs/heads/*) deny_long_lived_delete "git update-ref -d" "${ref#refs/heads/}" ;;
  esac
  return 0
}

# deny_long_lived_delete <what> <branch as written>: denies when the shell's spelling of the name
# (quotes and backslashes removed, braces expanded) is a long-lived branch.
deny_long_lived_delete() {
  local what="$1" b="${2//[\"\'\\]/}" x
  brace_words "$b"
  if [ "$BRACE_OVER" -eq 1 ]; then
    deny "${what} deleting a branch whose braces make more names than the guard reads, which may be a long-lived branch of this flow" \
      "name the branch in full; deleting a long-lived branch is the user's call"
  fi
  for x in "${BRACE_OUT[@]}"; do
    if is_long_lived_branch "$x"; then
      deny "${what} deleting '${x}': it is a long-lived branch of this flow, and deleting it is not a step of any task" \
        "to refresh a stale local copy, update it instead (git fetch origin ${x}:${x}, or work from origin/${x} in a worktree); deleting a long-lived branch is the user's call"
    fi
  done
  return 0
}

# --- One worktree per task (policy: one_worktree_per_task) --------------------
# With `one_worktree_per_task: true`, switching branches in a SHARED checkout is denied: every
# session working in that checkout sees its files change under it. A task gets its own worktree
# (`git worktree add`). Shared = the MAIN worktree (git-dir == git-common-dir: not a linked one)
# of the repository this guard protects, of a repository next to it (same parent directory) or of
# one inside it. A linked worktree, and a clone anywhere else, belongs to whoever made it: allowed.
# Restoring files is not switching: `git checkout -- <path>`, `git checkout <existing path>`,
# `git checkout -p`. Off by default (absent = false): a repository opts in.
#
# Where the git command runs: the session's directory (the hook input's `cwd`), moved by every
# `cd`/`pushd`/`popd` met so far in the command (SEG_CDS, in order) that holds where the command
# stands (see seg_counts), and by git's own `-C`. A directory the guard cannot resolve (a `cd` into a
# variable or a substitution, `--git-dir`/`--work-tree`) is not judged.
SEG_CDS=()
# The nesting past which the extractor does not read scopes (SCOPE_DEPTH_MAX in EXTRACT_JS).
SCOPE_DEPTH_MAX=400
# Where the segment being judged stands, from the extractor's position lines ("\x01<o> <p>", see
# "Where each segment stands" in EXTRACT_JS): SEG_POS_O its offsets ("12", "40.7"), SEG_POS_P the
# scopes around it ("/", "/12/q30/"). Empty SEG_POS_O: no position known, and every cd counts; "!":
# the extractor could not read the scopes (see command_git_dir).
SEG_POS_O=""
SEG_POS_P="/"
# pos_le <a> <b>: does position a stand at or before position b? Compared offset by offset.
pos_le() {
  local a="$1." b="$2." x y
  while [ -n "$a" ] && [ -n "$b" ]; do
    x="${a%%.*}" y="${b%%.*}"
    [ "$x" -lt "$y" ] && return 0
    [ "$x" -gt "$y" ] && return 1
    a="${a#*.}" b="${b#*.}"
  done
  [ -z "$a" ]
}
# seg_counts <o> <p>: does a cd recorded at that position count where this segment stands? Its
# scope must enclose this one (or be it), and it must stand before. A cd recorded without a position
# counts everywhere, as before positions existed.
seg_counts() {
  [ -n "$1" ] && [ -n "$SEG_POS_O" ] || return 0
  [[ "$SEG_POS_P" == "$2"* ]] || return 1
  pos_le "$1" "$SEG_POS_O"
}
SESSION_CWD=""
SESSION_CWD_READ=0
CMD_GIT_DIR=""

# The session's working directory, from the hook input; the hook's own directory without one.
load_session_cwd() {
  [ "$SESSION_CWD_READ" -eq 1 ] && return 0
  SESSION_CWD_READ=1
  SESSION_CWD="$(printf '%s' "${INPUT:-}" | node -e '
    let d = {};
    try { d = JSON.parse(require("fs").readFileSync(0, "utf8")); } catch (e) {}
    const c = d && typeof d.cwd === "string" ? d.cwd : "";
    if (!/[\n\r]/.test(c)) process.stdout.write(c);
  ' 2>/dev/null || true)"
  [ -n "$SESSION_CWD" ] || SESSION_CWD="$PWD"
  return 0
}

# resolve_dir <path> <base>: the physical directory <path> names from <base> (`~`, $HOME and
# ${HOME} expanded), in RESOLVED_DIR, or exit 1 when it does not exist or holds an expansion the guard
# cannot read. Each answer is kept for the rest of the process (the file system does not change while
# the guard judges): command_git_dir resolves every cd before each git command, and 60 cd/push pairs
# took some 1,800 subshells (main judged them in 0.3 s). Kept in a list, which the bash 3.2 of macOS
# can hold.
RESOLVED_DIR=""
RESOLVED_KEYS=()
RESOLVED_VALS=()
resolve_dir() {
  local p="$1" base="$2" h="${BASH_GUARD_HOME:-${HOME:-}}" k r
  RESOLVED_DIR=""
  # shellcheck disable=SC2088,SC2016 # the patterns are the LITERAL spellings, as a command writes them
  case "$p" in
    "~") p="$h" ;;
    "~/"*) p="$h/${p#\~/}" ;;
    '$HOME' | '${HOME}') p="$h" ;;
    '$HOME/'*) p="$h/${p#\$HOME/}" ;;
    '${HOME}/'*) p="$h/${p#\$\{HOME\}/}" ;;
  esac
  case "$p" in '' | *'$'* | *'`'*) return 1 ;; esac
  case "$p" in
    /*) ;;
    *)
      [ -n "$base" ] || return 1
      p="$base/$p"
      ;;
  esac
  for ((k = 0; k < ${#RESOLVED_KEYS[@]}; k++)); do
    [ "${RESOLVED_KEYS[k]}" = "$p" ] || continue
    RESOLVED_DIR="${RESOLVED_VALS[k]}"
    [ -n "$RESOLVED_DIR" ]
    return
  done
  r="$(cd "$p" 2>/dev/null && pwd -P)" || r=""
  RESOLVED_KEYS+=("$p")
  RESOLVED_VALS+=("$r")
  RESOLVED_DIR="$r"
  [ -n "$r" ]
}

# The directory the git command of this segment runs in -> CMD_GIT_DIR; exit 1 when unknown.
# `cd -` goes back to the directory before the last change, `popd` to the one the last `pushd`
# left; the session's own previous directory and stack are not known.
command_git_dir() {
  local d t k kind prev="" nd po pp
  local -a stack=()
  if [ "$SEG_POS_O" = "!" ] && [ "${#SEG_CDS[@]}" -gt 0 ]; then
    deny "the command nests its subshells deeper than the guard reads (${SCOPE_DEPTH_MAX}), so it cannot tell which of its cd/pushd/popd still hold where this git command runs" \
      "split it: run the cd and the git command in a command of their own (cd <dir> && git …), or use git -C <dir>"
  fi
  load_session_cwd
  resolve_dir "$SESSION_CWD" "" || return 1
  d="$RESOLVED_DIR"
  for t in ${SEG_CDS[@]+"${SEG_CDS[@]}"}; do
    check_deadline
    po="${t%%$'\t'*}"
    t="${t#*$'\t'}"
    pp="${t%%$'\t'*}"
    t="${t#*$'\t'}"
    seg_counts "$po" "$pp" || continue
    kind="${t%%$'\t'*}"
    t="${t#*$'\t'}"
    if [ "$kind" = popd ]; then
      [ "${#stack[@]}" -gt 0 ] || return 1
      nd="${stack[${#stack[@]} - 1]}"
      unset 'stack[${#stack[@]}-1]'
    elif [ "$t" = "-" ]; then
      [ "$kind" = cd ] && [ -n "$prev" ] || return 1
      nd="$prev"
    else
      resolve_dir "$t" "$d" || return 1
      nd="$RESOLVED_DIR"
      [ "$kind" = pushd ] && stack+=("$d")
    fi
    prev="$d"
    d="$nd"
  done
  for ((k = 0; k < ${#GIT_GLOBALS[@]}; k++)); do
    case "${GIT_GLOBALS[k]}" in
      -C)
        resolve_dir "${GIT_GLOBALS[k + 1]}" "$d" || return 1
        d="$RESOLVED_DIR"
        k=$((k + 1))
        ;;
      -c) k=$((k + 1)) ;;
      --git-dir | --work-tree | --git-dir=* | --work-tree=* | --bare) return 1 ;;
    esac
  done
  CMD_GIT_DIR="$d"
  return 0
}

# The main checkout of the repository this guard protects (the first entry of `git worktree
# list`), or nothing when it cannot be told.
own_main_checkout() {
  local root="${BASH_GUARD_PROJECT_ROOT:-$ANCHOR_ROOT}" out line
  [ -n "$root" ] && [ -d "$root" ] || return 0
  out="$(git_clean -C "$root" worktree list --porcelain 2>/dev/null)" || return 0
  line="${out%%$'\n'*}"
  case "$line" in "worktree "*) ;; *) return 0 ;; esac
  case "$out" in *$'\nbare'*) return 0 ;; esac
  (cd "${line#worktree }" 2>/dev/null && pwd -P) || true
}

# Is <dir> inside a shared checkout? Prints its top level when it is.
shared_checkout() {
  local d="$1" gd common top mine
  gd="$(git_clean -C "$d" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  gd="$(cd "$gd" 2>/dev/null && pwd -P)" || return 1
  common="$(cd "$d" 2>/dev/null && cd "$(git_clean rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)" || return 1
  [ "$gd" = "$common" ] || return 1
  top="$(git_clean -C "$d" rev-parse --show-toplevel 2>/dev/null)" || return 1
  top="$(cd "$top" 2>/dev/null && pwd -P)" || return 1
  mine="$(own_main_checkout)"
  # Not knowing which repository this guard protects leaves every main checkout shared.
  if [ -n "$mine" ] && [ "$top" != "$mine" ] && [ "${top%/*}" != "${mine%/*}" ]; then
    case "$top" in "$mine"/*) ;; *) return 1 ;; esac
    # A repository nested inside a linked worktree (`git init <worktree>/tmp/x`) belongs to that
    # worktree's task, not to the shared checkout (#311 (b)). Told by where it is, under
    # `.claude/worktrees/<task>/`, where this flow puts every worktree: a `.git` file, or an entry
    # in `.git/worktrees`, is something anyone can write (independent review of #311).
    case "$top" in "$mine"/.claude/worktrees/?*/?*) return 1 ;; esac
  fi
  printf '%s' "$top"
}

check_git_switch() {
  local sub="$1" i="$2" a p newb=0 first="" top
  [ "$ONE_WORKTREE_PER_TASK" = "true" ] || return 0
  local -a args=("${tok[@]:i}")
  for a in ${args[@]+"${args[@]}"}; do
    case "$a" in -h | --help) return 0 ;; esac
  done
  command_git_dir || return 0
  if [ "$sub" = checkout ]; then
    local k=0 pfile=0
    for a in ${args[@]+"${args[@]}"}; do
      k=$((k + 1))
      case "$a" in
        # `--` restores the paths after it; with none (a redirection, a comment or an expansion
        # that may be empty are not paths), `git checkout feature --` switches.
        --)
          # Paths a substitution prints (the segment cut at it, PARTIAL) or xargs appends (SEG_XARGS)
          # follow `--` without showing: `git checkout HEAD -- $(git diff --name-only)` restores.
          # xargs with a replace string (`-I{}`) appends nothing: it fills in where `{}` stands.
          if [ "${PARTIAL:-0}" -eq 1 ] || { [ "${SEG_XARGS:-0}" -eq 1 ] && [ -z "${SEG_REPL:-}" ]; }; then return 0; fi
          local skip=0
          for p in "${args[@]:k}"; do
            if [ "$skip" -eq 1 ]; then skip=0; continue; fi
            case "$p" in
              '#'*) break ;;
              # A redirection's target is not a path: glued (`2>/dev/null`) or the next word.
              *'>' | *'<') skip=1 ;;
              '' | '""' | "''" | *'>'* | '<'*) ;;
              *) return 0 ;;
            esac
          done
          break
          ;;
        -p | --patch) return 0 ;;
        -b | -B | --orphan) newb=1 ;;
        # Its value is a file of paths, not a path restored: empty, the branch is switched. Git takes
        # any unambiguous prefix (`--pathspec-from`).
        --pathspec-fr*) pfile=1 ;;
      esac
    done
    if [ "$newb" -eq 0 ] && [ "$pfile" -eq 0 ]; then
      for a in ${args[@]+"${args[@]}"}; do
        case "$a" in -*) continue ;; esac
        # `git checkout <rev> <path>…` restores files, without `--` too: a path after the first
        # word means no branch is switched (#311).
        [ -n "$first" ] && [ -e "$CMD_GIT_DIR/$a" ] && return 0
        [ -n "$first" ] || first="$a"
      done
      [ -n "$first" ] && [ -e "$CMD_GIT_DIR/$first" ] && return 0
    fi
  fi
  top="$(shared_checkout "$CMD_GIT_DIR")" || return 0
  deny "git ${sub} switches branches in the shared checkout ${top}: one worktree per task, and other sessions work in that checkout" \
    "git worktree add .claude/worktrees/<branch> -b <branch> origin/${INTEGRATION_BRANCH:-$PROTECTED_BRANCH}, and work there"
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
  # The `--repo` of the original command MUST be forwarded. The hook runs in
  # whatever directory the session's shell is in (or in $CLAUDE_PROJECT_DIR, when
  # a repo wires it with a `cd`), and neither is the PR's repository, so without
  # it `gh pr view` resolves the number against the wrong repo. Measured from one
  # repo against a PR of another: "Could not resolve to a PullRequest with the
  # number of 439", which the fail-closed branch below turns into the protected
  # branch — so every cross-repo merge was denied no matter what the policy said.
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
  long_lived_names
  for x in "${LONG_LIVED_NAMES[@]}"; do
    [ "$b" = "$x" ] && return 0
  done
  return 1
}

# Every long-lived branch name, in LONG_LIVED_NAMES: the built-in floor, then the policy's.
LONG_LIVED_NAMES=()
long_lived_names() {
  LONG_LIVED_NAMES=(main master develop development trunk "$PROTECTED_BRANCH")
  [ -n "$INTEGRATION_BRANCH" ] && LONG_LIVED_NAMES+=("$INTEGRATION_BRANCH")
  LONG_LIVED_NAMES+=(${LONG_LIVED_BRANCHES[@]+"${LONG_LIVED_BRANCHES[@]}"})
  return 0
}

# The "owner/name" a gh --repo value names (OWNER/REPO, HOST/OWNER/REPO or a URL), lowercase;
# nothing when it does not parse.
repo_arg_identity() {
  case "$1" in
    *://*) remote_identity "$1" ;;
    */*/*) remote_identity "ssh://h/${1#*/}" ;;
    */*) remote_identity "ssh://h/$1" ;;
  esac
  return 0
}

# Which repository does this `gh pr merge` land in, and is it THIS one — the one
# that vendored this guard, whose policy was loaded at the top of this file?
# Prints the target's "owner/name" (lowercase) and returns:
#   0  provably this repository -> the policy already loaded governs it
#   1  another repository, the one printed -> its own policy governs it
#   2  cannot be determined -> the caller denies
# The cwd is NOT evidence of who we are: the hook runs wherever the session's shell
# is, and that follows every `cd`, so the directory says where you STOOD, never who
# you ARE. What decides is the repository that HOLDS the guard, as for the protected
# branch of a push (project_identities).
# Without --repo, gh resolves the PR in the repository of the directory it runs in;
# that directory counts as ours only when EVERY one of its remotes is ours, and a
# relocation in the command (`cd`, GH_REPO=) makes it unknowable.
# TEST-ONLY override: BASH_GUARD_OWN_REPO is this repository's "owner/name", and
# also stands for the cwd when no --repo is given.
merge_target() {
  local repo="$1" ids="" t="" remotes="" urls="" r u d any=0
  if [ -n "${BASH_GUARD_OWN_REPO+x}" ]; then
    ids="$(printf '%s' "$BASH_GUARD_OWN_REPO" | tr '[:upper:]' '[:lower:]')"
    if [ -z "$repo" ]; then
      [ -n "$ids" ] || return 2
      printf '%s' "$ids"
      return 0
    fi
  else
    ids="$(project_identities)" || ids=""
  fi
  if [ -n "$repo" ]; then
    t="$(repo_arg_identity "$repo")"
    [ -n "$t" ] || return 2
    printf '%s' "$t"
    identity_in "$t" "$ids" && return 0
    return 1
  fi
  command_relocates && return 2
  [ -n "${ids//$'\n'/}" ] || return 2
  remotes="$(git_clean remote 2>/dev/null)" || return 2
  for r in $remotes; do
    urls+="$(git_clean remote get-url --all "$r" 2>/dev/null)"$'\n'
  done
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    d="$(remote_identity "$u")" || d=""
    [ -n "$d" ] || return 2
    identity_in "$d" "$ids" || return 2
    [ "$any" -eq 1 ] || t="$d"
    any=1
  done <<<"$urls"
  [ "$any" -eq 1 ] || return 2
  printf '%s' "$t"
  return 0
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
  local repo="$1"
  if [ -n "${BASH_GUARD_TARGET_POLICY:-}" ]; then
    policy_tsv_from_file "$BASH_GUARD_TARGET_POLICY"
    return 0
  fi
  api_policy_tsv "$repo" || true
}

# <owner/name>'s guard.policy.json as its default branch carries it, through the API. Prints
# the policy TSV and returns 0 when it was read; returns 3 when the repository PROVABLY vendors
# no policy (HTTP 404: no such file, or no repository this token can see); returns 1 for
# anything else (no network, rate limit, an answer that does not decode). Only a push needs the
# difference — for a merge both mean "unknown", which denies — because "no policy" is exactly
# the repository whose own flow may be to push to its main (see check_git_push).
api_policy_tsv() {
  local repo="$1" content="" err="" rc=0 tmp tsv
  err="$(mktemp 2>/dev/null)" || return 1
  content="$(gh api "repos/${repo}/contents/scripts/hooks/guard.policy.json" --jq .content 2>"$err")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    if grep -q 'HTTP 404' "$err" 2>/dev/null; then rc=3; else rc=1; fi
    rm -f "$err"
    return "$rc"
  fi
  rm -f "$err"
  content="$(printf '%s' "$content" | base64 -d 2>/dev/null)" || return 1
  [ -n "$content" ] || return 1
  tmp="$(mktemp 2>/dev/null)" || return 1
  printf '%s' "$content" >"$tmp"
  tsv="$(policy_tsv_from_file "$tmp")"
  rm -f "$tmp"
  [ -n "$tsv" ] || return 1
  printf '%s' "$tsv"
}

# The policy of the repository the PUBLISHED guard protects (`--project <dir>`), as
# origin's default branch carries it — never the working tree's (see "Which
# repository, and which copy of its policy" at the top). Empty output = could not
# read it, and the caller keeps the strict defaults.
#   1. refs/remotes/origin/HEAD, resolved and read with `git show`: no network per
#      command. It moves on fetch (and on a push to that branch), not on an edit.
#   2. The API, through target_policy_tsv, for a clone without origin/HEAD or a ref
#      that lacks the file. Only for a GitHub-shaped origin: a local path has no API.
published_policy_tsv() {
  local root="$1" ref="" tmp="" tsv="" url="" id=""
  [ -n "$root" ] && [ -d "$root" ] || return 0
  ref="$(git_clean -C "$root" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null)" || ref=""
  if [ -n "$ref" ] && tmp="$(mktemp 2>/dev/null)"; then
    if git_clean -C "$root" show "${ref}:scripts/hooks/guard.policy.json" >"$tmp" 2>/dev/null && [ -s "$tmp" ]; then
      tsv="$(policy_tsv_from_file "$tmp")"
    fi
    rm -f "$tmp"
  fi
  if [ -z "$tsv" ]; then
    url="$(git_clean -C "$root" remote get-url origin 2>/dev/null)" || url=""
    id="$(remote_identity "$url")"
    case "$id" in
      local:*) ;;
      ?*/?*) tsv="$(target_policy_tsv "$id")" ;;
    esac
  fi
  printf '%s' "$tsv"
}

# Half of the merges this guard could not resolve in the 30 days to 2026-09-30 (20 of 38) were
# not merges at all: `gh pr merge <n>` as TEXT inside another command — a sed pattern editing a
# doc, a grep, a python string. The guard reads every quoted span as a possible command too,
# because `bash -c "…"` does run it, and it cannot tell a pattern from a script without letting
# some script through. So those stay denied, and the message says how to do the edit instead.
MERGE_MENTION_HINT="If this is text that is not meant to run (a sed or grep pattern, a doc being edited), the guard reads quoted text as a possible command too: make the edit with the Edit tool instead"

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
# WHOSE POLICY DECIDES. Not the SESSION's — the policy loaded at the top of this
# file is simply the only one at hand, and being at hand is not being in charge.
# Whoever merges does not set the conditions: a merge landing in another repo
# re-reads THAT repo's guard.policy.json from its origin and decides with it,
# failing CLOSED when it cannot be read. Which repo the merge lands in is
# merge_target's call, and the cwd has no say in it. The globals
# are reassigned rather than shadowed on purpose: this process exits right after,
# and threading four values through three helpers would be the kind of change
# that quietly stops covering one of them.
# Two things are settled before whose policy decides, both about READING the command:
#   - a PR or a --repo the shell fills in later (`gh pr merge $N --repo "$R"`, a loop, a
#     substitution, an option that expands into options) cannot be looked up: the guard reads
#     the command BEFORE it runs. It is denied, as it always was — but saying why, instead of
#     "could not resolve PR '$N'", which sent the agent to check a number that was fine.
#   - a PR given by URL names its repository: `gh pr merge https://github.com/o/n/pull/5` lands
#     in o/n from any directory, so that is the target (and a --repo naming another repository
#     next to it cannot be told apart from it: denied).
check_pr_merge() {
  local pr="$1" repo="${2:-}" pr_exp="${3:-0}" repo_exp="${4:-0}" refs base head target rc=0 tsv foreign=0
  local url_repo="" shown
  if [ "$pr_exp" = 1 ] || [ "$repo_exp" = 1 ]; then
    shown="gh pr merge ${pr}${repo:+ --repo $repo}"
    shown="${shown//\$__GUARD_SUBST__/\$(…)}"
    shown="${shown//"$XARGS_PLACEHOLDER"/<from xargs>}"
    deny "'${shown}' names its PR or its repository with something the shell fills in later (a variable, a substitution, a loop, xargs), and the guard reads the command before it runs, so it cannot look the PR up" \
      "write both literally, one merge per command: gh pr merge <number> --repo <owner>/<name>"
  fi
  url_repo="$(pr_url_repo "$pr")"
  if [ -n "$url_repo" ]; then
    if [ -z "$repo" ]; then
      repo="$url_repo"
    elif [ "$(repo_arg_identity "$repo")" != "$(repo_arg_identity "$url_repo")" ]; then
      deny "gh pr merge names a PR of ${url_repo} by URL and --repo ${repo}: two repositories, so the policy that governs it is unknown" \
        "use one of them: gh pr merge <number> --repo <owner>/<name>"
    fi
  fi
  target="$(merge_target "$repo")" || rc=$?
  case "$rc" in
    0) ;;
    1)
      foreign=1
      tsv="$(target_policy_tsv "$target")"
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
      ;;
    *)
      deny "gh pr merge$([ -n "$repo" ] && printf " --repo %s" "$repo"): cannot tell which repository this PR belongs to, so the policy that governs it is unknown" \
        "name it explicitly, without moving the shell first: gh pr merge <n> --repo <owner>/<name>. ${MERGE_MENTION_HINT}"
      ;;
  esac

  if [ "$AGENT_MAY_MERGE" != "true" ]; then
    deny_human_merge "gh pr merge merges the PR from the CLI$([ "$foreign" -eq 1 ] && printf ", and %s reserves its merges to a human" "$repo")"
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
      "pass the PR's repository explicitly (gh pr merge <n> --repo <owner>/<name>) and check the number exists. ${MERGE_MENTION_HINT}"
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
# The words of a `gh` segment as the SHELL splits them — quotes honoured, through egress_words —
# starting after the command word. The prefixes check_segment skips (assignments, env and its
# options, sudo/command/exec/nohup/time and shell keywords) are skipped the same way, so both
# readings agree on which word is `gh`. GHW holds each word's text; GHX is 1 for a word the shell
# fills in (a `$` or backtick it would expand, quoted or not), whose value the guard cannot read.
#
# Why not the whitespace tokens every other rule reads: `gh pr merge --subject "docs: a b" 7`
# makes `a` the PR for them, and `--subject 5 7` makes it 5 — a different PR than the one gh
# merges, possibly with another base. The PR a merge names is the one thing this rule must read
# right.
GHW=()
GH_PH_EXTRA=0
GHX=()
GHB=()
GH_OPAQUE=0
# The word that stands for what xargs appends (see prefix_end): a `$` makes every rule that asks
# "is this word literal?" get a truthful no.
# shellcheck disable=SC2016 # literal on purpose
XARGS_PLACEHOLDER='$__XARGS__'
# xargs_valued_prefix <word>: is it an unambiguous prefix of one of xargs' long options that take
# their value as the next word (`--delim ,` is --delimiter)? GNU getopt takes any such prefix, and
# its value read as the command word left the command judged by no rule (independent review of #324).
xargs_valued_prefix() {
  local o hits=0
  [ "${#1}" -ge 3 ] || return 1
  # --eof and --max-lines take their value only with `=`: the next word is the command.
  for o in --arg-file --delimiter --max-args --max-procs --max-chars --process-slot-var; do
    [[ "$o" == "$1"* ]] && hits=$((hits + 1))
  done
  [ "$hits" -eq 1 ]
}
gh_words() {
  local w k=0 n
  GHW=()
  GHX=()
  GHB=()
  egress_words "$1"
  n=${#EGRESS_WORDS[@]}
  PFX_W=()
  PFX_RAW=()
  for w in ${EGRESS_WORDS[@]+"${EGRESS_WORDS[@]}"}; do
    w="${w//$'\x1e'/}"
    PFX_W+=("${w//$'\x1f'/\$}")
  done
  prefix_end
  k=$PFX_END
  # Both readings must land on the same word. If this one does not see `gh` where check_segment
  # did, it cannot say which words are gh's: GH_OPAQUE tells check_gh to fail closed.
  GH_OPAQUE=0
  w="${EGRESS_WORDS[k]:-}"
  w="${w//$'\x1e'/}"
  base_name "$w"
  [ "$BASE_NAME" = "gh" ] || GH_OPAQUE=1
  for ((k = k + 1; k < n; k++)); do
    w="${EGRESS_WORDS[k]}"
    if [[ "$w" == *'$'* || "$w" == *'`'* ]]; then GHX+=(1); else GHX+=(0); fi
    # GHB: the shell multiplies this word (an unquoted brace that expands, see egress_words).
    if [[ "$w" == *$'\x1e'* ]]; then GHB+=(1); else GHB+=(0); fi
    w="${w//$'\x1e'/}"
    w="${w//$'\x1f'/\$}"
    # A word holding xargs' replace string is filled in from stdin.
    [ -n "$PFX_REPL" ] && [[ "$w" == *"$PFX_REPL"* ]] && GHX[${#GHX[@]} - 1]=1
    GHW+=("$w")
  done
  # Without a replace string, xargs appends what it reads to the command: one more word, unknown.
  # GH_PH_EXTRA: that word is there only because a replace string may be cancelled (2.9.18 added it
  # with no replace string alone); a rule that would read it as a value given loosely skips it.
  GH_PH_EXTRA=0
  if [ "$PFX_XARGS" -eq 1 ] && [ "$PFX_APPEND" -eq 1 ]; then
    GHW+=("$XARGS_PLACEHOLDER")
    GHX+=(1)
    [ -n "$PFX_REPL" ] && GH_PH_EXTRA=1
  fi
  return 0
}

# gh options that take their value in the NEXT word: the global ones, then those of the
# subcommands this guard reads. A value is never the PR, never a subcommand and never a flag.
GH_VALUE_GLOBAL=" -R --repo --hostname "
GH_VALUE_PR_MERGE=" -b --body -F --body-file -t --subject -A --author-email --match-head-commit "
GH_VALUE_PR_CREATE=" -a --assignee -B --base -b --body -F --body-file -H --head -l --label -m --milestone -p --project -r --reviewer -T --template -t --title --recover "
GH_VALUE_API=" -X --method -H --header -F --field -f --raw-field --input -q --jq -t --template --cache -p --preview "
GH_VALUE_EDIT=" -B --base -b --body -F --body-file -m --milestone -t --title --add-assignee --remove-assignee --add-label --remove-label --add-project --remove-project --add-reviewer --remove-reviewer --attach --add-blocked-by --add-blocking --add-sub-issue --parent --remove-blocked-by --remove-blocking --remove-sub-issue --type "
GH_VALUE_LABEL_EDIT=" -c --color -d --description -n --name "

# A word of short options, as gh's flag parser (pflag) reads it: its letters in order, until one
# takes a value (listed in $2, the " -x " set in force) or is followed by `=`. That letter goes in
# SC_LETTER; its value is the rest of the word (one leading `=` dropped) in SC_VALUE, or, when
# nothing is left, the NEXT word, and then SC_NEXT is 1. No such letter: SC_LETTER is empty.
SC_LETTER=""
SC_VALUE=""
SC_NEXT=0
short_cluster() {
  local w="${1#-}" values="$2" k c
  SC_LETTER=""
  SC_VALUE=""
  SC_NEXT=0
  for ((k = 0; k < ${#w}; k++)); do
    c="${w:k:1}"
    if [[ "$values" == *" -$c "* ]] || [ "${w:k+1:1}" = "=" ]; then
      SC_LETTER="$c"
      SC_VALUE="${w:k+1}"
      [ -n "$SC_VALUE" ] || SC_NEXT=1
      SC_VALUE="${SC_VALUE#=}"
      return 0
    fi
  done
  return 0
}

# The repository a PR URL names (https://<host>/<owner>/<name>/pull/<n>[/…]), or nothing.
pr_url_repo() {
  local u="$1"
  case "$u" in
    http://*/pull/* | https://*/pull/*) ;;
    *) return 0 ;;
  esac
  u="${u#*://}"
  u="${u#*/}"
  u="${u%%/pull/*}"
  case "$u" in */*) printf '%s' "$u" ;; esac
}

check_gh() {
  # The first two positionals are the subcommands; for `pr merge` the next one is the PR
  # (number, URL or branch). Global options, and the options of `pr merge` / `pr create` that
  # take a value, are skipped with their value. The scan does NOT stop at the PR: `--repo`
  # usually comes AFTER it (`gh pr merge 123 --repo owner/name --squash`).
  local i=0 n w sub1="" sub2="" sub2_x=0 merge_arg="" merge_set=0 repo_arg="" repo_exp=0 pr_exp=0
  local has_label=0 opts_done=0 opaque=0 values="$GH_VALUE_GLOBAL" a admin=0 label_arg="" label_x=0 label_set=0
  local alias_shell=0 label_mut=0
  local -a removed=() removed_x=() alias_pos=() alias_pos_x=()
  gh_words "$seg"
  opaque="$GH_OPAQUE"
  n=${#GHW[@]}
  # A word the shell multiplies past what brace_words reads may become any words (#306). In the
  # subcommand slots (`gh {api,-f=<2100 x>} -X DELETE …`) it may be any subcommand; in `gh api` it
  # may be the method or a field that makes the call write (`{-XDELETE,-H…}`). Elsewhere (a long
  # value, `--{delete-branch,…}`) the rules below read it; a quoted one is one word, untouched.
  local pos=0 skipv=0 sub_api=0
  for ((i = 0; i < n; i++)); do
    w="${GHW[i]}"
    if [ "$skipv" -eq 1 ]; then skipv=0; continue; fi
    case "$w" in
      -R | --repo | --hostname) skipv=1; continue ;;
      -*) ;;
      *)
        pos=$((pos + 1))
        [ "$pos" -eq 1 ] && [ "$w" = api ] && sub_api=1
        ;;
    esac
    [ "${GHB[i]:-0}" -eq 1 ] && [ "${#w}" -gt "$BRACE_MAX_LEN" ] || continue
    # The second slot of `gh api` is its endpoint, which check_gh_api_braces reads.
    if [ "$pos" -lt 2 ] || { [ "$pos" -eq 2 ] && [ "$sub_api" -eq 0 ] && [[ "$w" != -* ]]; }; then
      deny "gh with a word in its subcommand slots whose braces expand past what the guard reads (${#w} characters): it may turn into any subcommand or flag" \
        "write the subcommand out; quote a long value that holds braces"
    fi
    if [ "$sub_api" -eq 1 ] && { could_spell "$w" -X || could_spell "$w" --method || could_spell "$w" -f || could_spell "$w" -F || could_spell "$w" --input; }; then
      deny "gh api with a word whose braces expand past what the guard reads (${#w} characters) and may spell its method or a field, so the guard cannot tell whether it writes" \
        "write the method and fields out; quote a long value that holds braces"
    fi
  done
  i=0
  while [ "$i" -lt "$n" ]; do
    w="${GHW[i]}"
    # Brace expansion makes several words of one (`--{admin,squash}`): the flags read below are
    # looked for in each of them too.
    if [ "$opts_done" -eq 0 ] && [[ "$w" == *'{'*,* ]]; then
      brace_words "$w"
      # Past what brace_words reads, the word may be any flag it could spell.
      if [ "$BRACE_OVER" -eq 1 ]; then
        could_spell "$w" --admin && admin=1
        if could_spell "$w" --remove-label=; then
          removed+=("$w")
          removed_x+=("${GHX[i]}")
        fi
      fi
      for a in "${BRACE_OUT[@]}"; do
        case "$a" in
          --admin) admin=1 ;;
          --admin=*) admin_value "${a#*=}" "${GHX[i]}" && admin=1 ;;
          --remove-label=*)
            removed+=("${a#*=}")
            removed_x+=("${GHX[i]}")
            ;;
        esac
      done
    fi
    if [ "$opts_done" -eq 0 ]; then
      case "$w" in
        --)
          opts_done=1
          i=$((i + 1))
          continue
          ;;
        -R | --repo)
          # Captured, not just skipped: pr_refs needs it to look the PR up in the RIGHT
          # repository, and merge_target to know whose policy decides.
          repo_arg="${GHW[i + 1]:-}"
          repo_exp="${GHX[i + 1]:-0}"
          i=$((i + 2))
          continue
          ;;
        -R=* | --repo=*)
          repo_arg="${w#*=}"
          repo_exp="${GHX[i]}"
          i=$((i + 1))
          continue
          ;;
        # Recorded wherever they stand (gh's flag parser takes them before or after the
        # subcommands), and judged once the subcommands are known.
        --admin) admin=1 ;;
        --admin=*) admin_value "${w#*=}" "${GHX[i]}" && admin=1 ;;
        --remove-label)
          removed+=("${GHW[i + 1]-}")
          removed_x+=("${GHX[i + 1]:-0}")
          ;;
        --remove-label=*)
          removed+=("${w#*=}")
          removed_x+=("${GHX[i]}")
          ;;
        # `gh alias set --shell`: the expansion is a shell command (see the alias rule below).
        -s | --shell) [ "$sub1 $sub2" = "alias set" ] && alias_shell=1 ;;
      esac
      case "$w" in
        --*=*)
          [ "${w%%=*}" = --label ] && label_named "${w#*=}" "${GHX[i]}" && has_label=1
          i=$((i + 1))
          continue
          ;;
        --?*)
          # An option the shell fills in may turn into any option at all (`--repo x`).
          [ "${GHX[i]}" = 1 ] && opaque=1
          [ "$w" = --label ] && label_named "${GHW[i + 1]-}" "${GHX[i + 1]:-0}" && has_label=1
          if [[ "$values" == *" $w "* ]]; then i=$((i + 2)); else i=$((i + 1)); fi
          continue
          ;;
        -?*)
          [ "${GHX[i]}" = 1 ] && opaque=1
          # A cluster of short options (`-sd`, `-st <subject>`, `-sRowner/name`), read the way
          # gh's flag parser reads it: see short_cluster. Taken for one unknown option, `gh pr
          # merge -st 123 456` made 123 the PR while gh merged 456, and `-Rowner/name` left the
          # repository to an earlier --repo while gh used the last one (found 2026-09-30).
          short_cluster "$w" "$values"
          case "$SC_LETTER" in
            R)
              if [ "$SC_NEXT" -eq 1 ]; then
                repo_arg="${GHW[i + 1]:-}"
                repo_exp="${GHX[i + 1]:-0}"
              else
                repo_arg="$SC_VALUE"
                repo_exp="${GHX[i]}"
              fi
              ;;
            l)
              if [ "$SC_NEXT" -eq 1 ]; then
                label_named "${GHW[i + 1]-}" "${GHX[i + 1]:-0}" && has_label=1
              else
                label_named "$SC_VALUE" "${GHX[i]}" && has_label=1
              fi
              ;;
          esac
          if [ "$SC_NEXT" -eq 1 ]; then i=$((i + 2)); else i=$((i + 1)); fi
          continue
          ;;
      esac
    fi
    if [ -z "$sub1" ]; then
      sub1="$w"
      # `gh api`'s options take values too: `-X POST graphql` names the endpoint graphql, not POST.
      [ "$sub1" = api ] && values+="${GH_VALUE_API# }"
    elif [ -z "$sub2" ]; then
      sub2="$w"
      sub2_x="${GHX[i]}"
      case "$sub1 $sub2" in
        "pr merge") values+="${GH_VALUE_PR_MERGE# }" ;;
        "pr create") values+="${GH_VALUE_PR_CREATE# }" ;;
        "pr edit" | "issue edit") values+="${GH_VALUE_EDIT# }" ;;
        "label edit") values+="${GH_VALUE_LABEL_EDIT# }" ;;
      esac
    elif [ "$sub1 $sub2" = "pr merge" ] && [ "$merge_set" -eq 0 ]; then
      merge_arg="$w"
      pr_exp="${GHX[i]}"
      merge_set=1
    elif { [ "$sub1 $sub2" = "label delete" ] || [ "$sub1 $sub2" = "label edit" ]; } && [ "$label_set" -eq 0 ]; then
      label_arg="$w"
      label_x="${GHX[i]}"
      label_set=1
    elif [ "$sub1 $sub2" = "alias set" ]; then
      alias_pos+=("$w")
      alias_pos_x+=("${GHX[i]}")
    elif [ "${GHX[i]}" = 1 ]; then
      # A positional gh would reject, unless the shell turns it into options (`--repo x`).
      opaque=1
    fi
    i=$((i + 1))
  done

  # `gh pr merge --admin` merges past branch protection and the required checks, so it is denied
  # whatever the policy says about merging (see "Merging belongs to GitHub Actions" below). No other
  # gh command has --admin, and --remove-label is `pr edit`'s, `issue edit`'s and `discussion
  # edit`'s: on any other first word (an alias, `gh pm 5 --admin`, or an extension that hands its
  # flags on) both rules still apply, and gh rejects the flag anyway where it is unknown.
  if [ "$admin" -eq 1 ]; then
    deny "gh pr merge --admin merges past the branch protection and the required checks, the gates every merge has to clear" \
      "merge without --admin once the checks are green, where the repository's policy lets an agent merge; a PR that protection still blocks is for a human: leave it ready and say so"
  fi
  # The human-review label and no-automerge come off only by a human's hand (see owner_label_word).
  if [ "${#removed[@]}" -gt 0 ]; then
    for ((i = 0; i < ${#removed[@]}; i++)); do
      owner_label_list "${removed[i]}" "${removed_x[i]}" || continue
      a="gh ${sub1} ${sub2} --remove-label '${removed[i]//\$__GUARD_SUBST__/\$(…)}'"
      if [ "${removed_x[i]}" = 1 ]; then
        deny_owner_label "${a} names the labels to take off with something the shell fills in later, which the guard cannot read: it may be ${HELD_LABEL}"
      fi
      deny_owner_label "${a} takes ${HELD_LABEL} off"
    done
  fi
  if [ "$label_set" -eq 1 ] && owner_label_word "$label_arg" "$label_x"; then
    a="gh label ${sub2} '${label_arg//\$__GUARD_SUBST__/\$(…)}'"
    if [ "$label_x" = 1 ]; then
      deny_owner_label "${a} names the label with something the shell fills in later, which the guard cannot read: it may be ${HELD_LABEL}"
    fi
    deny_owner_label "${a} deletes or rewrites the ${HELD_LABEL} label itself"
  fi
  # `gh alias set <name> <expansion>`: the alias runs its expansion later, out of the guard's sight,
  # with the alias's own arguments appended. So the expansion is judged now, as the command it will
  # be: a shell command (`--shell`, or `!` in front) as it stands, a gh one as `gh <expansion>` plus
  # arguments the shell fills in, and as half a command (PARTIAL), since which PR it merges and in
  # which repository are only known when it runs.
  # An expansion read from stdin (`-`) or filled in by the shell cannot be judged now, and `gh alias
  # import` defines its aliases from a file or stdin: both are denied, with the way that is read.
  if [ "$sub1 $sub2" = "alias import" ]; then
    deny "gh alias import defines aliases from a file or stdin, which the guard cannot read, and an alias runs its expansion later, out of the guard's sight" \
      "define each alias with gh alias set <name> '<expansion>', the expansion written in the command"
  fi
  if [ "$sub1 $sub2" = "alias set" ] && [ "${#alias_pos[@]}" -ge 2 ]; then
    a="${alias_pos[1]}"
    if [ "$a" = - ] || [ "${alias_pos_x[1]}" = 1 ]; then
      deny "gh alias set takes its expansion from stdin or from something the shell fills in, which the guard cannot read, and the alias runs it later, out of the guard's sight" \
        "write the expansion in the command: gh alias set <name> '<expansion>'"
    fi
    if [ "$alias_shell" -eq 1 ] || [[ "$a" == '!'* ]]; then
      check_segment "${a#!}"
    else
      check_segment $'\t'"gh ${a} ${XARGS_PLACEHOLDER}"
    fi
  fi

  # Half a command (see PARTIAL in check_segment) is not judged by the two rules that need the
  # WHOLE one: which PR, in which repository, and whether a label is there. Its masked twin, the
  # same command read whole, is.
  if [ "$sub1" = "pr" ] && [ "$sub2" = "merge" ] && [ "$PARTIAL" -eq 0 ]; then
    [ "$opaque" -eq 1 ] && pr_exp=1
    check_pr_merge "$merge_arg" "$repo_arg" "$pr_exp" "$repo_exp"
  fi

  # `gh pr create` without a label. The label is what the release gate reads, and putting it in a
  # SECOND command run afterwards is how it goes missing: measured 2026-08-14, five of ~20 PRs
  # opened in one session shipped unlabelled, each one red on its repo's require-semver-label gate.
  #
  # This denies the shape that loses the label, not the tool: `gh pr create --label X` passes
  # straight through. `pr-create.sh` is the comfortable path — it also checks the label EXISTS
  # (gh accepts a non-existent one, warns on stdout and still exits 0) and re-reads the PR
  # afterwards to prove it stuck.
  #
  # A repository whose releases do not read PR labels (release-please from the commits, say, or a
  # version bump in a manifest) waives it with `require_pr_label: false` — for PRs that land in
  # it, wherever the session runs; see pr_label_waived.
  if [ "$sub1" = "pr" ] && [ "$sub2" = "create" ] && [ "$PARTIAL" -eq 0 ]; then
    [ "$repo_exp" = 1 ] && opaque=1
    if [ "$has_label" -eq 0 ] && ! pr_label_waived "$repo_arg" "$opaque"; then
      deny "gh pr create without --label: the release gate reads a semver label from the PR, and a label left to a second command is how it gets forgotten" \
        "re-run the same command with it: --label semver:patch (fix), semver:minor (feat), semver:major (breaking) or semver:none (docs/chore/ci/test); core-dev's pr-create.sh also checks that the label exists and landed. A repository whose releases do not read labels says so in its guard.policy.json (require_pr_label: false), and then no label is needed"
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
    # The endpoint as gh reads it (quotes taken out) and as GitHub routes it: a query string or a
    # fragment after it still reaches the merge (see api_path).
    api_path "$sub2"
    if [[ "$API_PATH" =~ (^|/)pulls/[^/]+/merge$ || "$API_PATH" =~ (^|/)merges$ ]]; then
      deny_human_merge "gh api on a merge endpoint is equivalent to merging the PR"
    fi
    # The mutation may be split across segments by tokenization; search the
    # whole command (SEGMENTS is global), read without the shell's quotes and backslashes, which
    # GitHub never sees. Merging a PR, queueing it for the merge queue,
    # arming auto-merge and merging one branch into another are all merges.
    bare_text "$SEGMENTS"
    a="$BARE_TEXT"
    case "$a" in
      *mergePullRequest* | *enablePullRequestAutoMerge* | *enqueuePullRequest* | *mergeBranch*)
        deny_human_merge "gh api graphql with a merge mutation (mergePullRequest, enablePullRequestAutoMerge, enqueuePullRequest, mergeBranch) merges the PR"
        ;;
    esac
    # A label mutation names labels by id, which says nothing about which label it is: any one
    # that removes, replaces, renames or deletes labels may take revision-humana or no-automerge off.
    # labelIds may come before the mutation that uses it (`-F 'input[labelIds][]=' -f query=…`).
    # Only a request to the GraphQL endpoint (or to one the shell fills in) carries a mutation.
    if [[ "$API_PATH" == graphql || "$API_PATH" == */graphql || "$sub2_x" = 1 ]]; then
      case "$a" in
        *removeLabelsFromLabelable* | *clearLabelsFromLabelable* | *updateLabel* | *deleteLabel*) label_mut=1 ;;
        *updatePullRequest* | *updateIssue*) [[ "$a" == *labelIds* ]] && label_mut=1 ;;
      esac
    fi
    if [ "$label_mut" -eq 1 ]; then
      HELD_LABEL="$OWNER_LABELS"
      deny_owner_label "gh api graphql with a mutation that removes, replaces, renames or deletes labels (removeLabelsFromLabelable, clearLabelsFromLabelable, labelIds in updatePullRequest/updateIssue, updateLabel, deleteLabel) names them by id, so the guard cannot tell it leaves ${OWNER_LABEL} and ${NOAUTO_LABEL} alone"
    fi
    # The GraphQL twins of a ref's DELETE and PATCH (see check_gh_api_refs): deleteRef and updateRef
    # name the ref by its id, and updateRefs moves any number of them at once, with force when asked.
    # createCommitOnBranch commits onto any branch it names, main included: a push without git push.
    # The guard cannot tell they leave develop and main alone. No real command of the 31 days to
    # 2026-10-02 uses them.
    if [[ "$API_PATH" == graphql || "$API_PATH" == */graphql || "$sub2_x" = 1 ]]; then
      case "$a" in
        *deleteRef* | *updateRef* | *createCommitOnBranch*)
          deny "gh api graphql with a mutation that deletes, moves or commits onto refs (deleteRef, updateRef, updateRefs, createCommitOnBranch) names them by id, moves several at once or names the branch in a body, so the guard cannot tell it leaves the long-lived branches alone" \
            "update your own branch with git push (--force-with-lease after a rebase) and delete a finished one with git push origin --delete <branch>, which the guard reads; a long-lived branch is a human's"
          ;;
      esac
      # The GraphQL twins of writing branch protection and rulesets (see check_gh_api_protection).
      # Only the mutation names: a read may name the types (`... on BranchProtectionRule`). Only in
      # the request, read as GraphQL reads it, when the guard can read it all (gql_document): a grep
      # or an echo in the same command, and a comment body inside another mutation, are not one
      # (found 2026-10-03, verifying this change). Otherwise in the whole command, as above.
      local doc="$a"
      gql_document && doc="$GQL_DOC"
      case "$doc" in
        *createBranchProtectionRule* | *updateBranchProtectionRule* | *deleteBranchProtectionRule* | *createRepositoryRuleset* | *updateRepositoryRuleset* | *deleteRepositoryRuleset*)
          deny "gh api graphql with a mutation that creates, changes or deletes a branch protection rule or a ruleset (createBranchProtectionRule, updateBranchProtectionRule, deleteBranchProtectionRule, createRepositoryRuleset, updateRepositoryRuleset, deleteRepositoryRuleset): branch protection and rulesets are the repository owner's settings" \
            "$PROTECTION_HINT"
          ;;
      esac
    fi
    check_gh_api_braces "$sub2"
    check_gh_api_labels "$sub2" "$sub2_x"
    check_gh_api_refs "$sub2" "$sub2_x"
    check_gh_api_protection "$sub2" "$sub2_x"
    case "$sub2" in
      graphql | */graphql) [ "$PARTIAL" -eq 0 ] && check_gh_graphql_query ;;
    esac
  fi
  return 0
}

# Does this --label value name a label? <value> <1 if the shell fills it in>. An empty one (or
# only commas and blanks) adds none; one the shell fills in counts, like any other option value.
label_named() {
  local v="$1" x="${2:-0}"
  [ "$v" = "$XARGS_PLACEHOLDER" ] && [ "${GH_PH_EXTRA:-0}" -eq 1 ] && return 1
  [ "$x" = 1 ] && return 0
  v="${v//[[:space:],]/}"
  [ -n "$v" ]
}

# The merge mutations above are read in the command, so a `gh api graphql` whose query is NOT
# written in the command cannot be judged: the query must be text in it. Denied: the request body
# from a file or stdin (--input), the query field from a file or stdin (-F query=@…), an empty
# query, a query cut short (more `{` than `}`: the rest of it is not in what the guard
# reads), a command substitution or backtick anywhere in it, and a shell variable in any query
# that is not a read: only a query whose own text starts with `{` or `query` (an operation that
# cannot be a mutation) may hold one (`issue(number:$n)` in a loop).
GQL_NOT_WRITTEN_HINT="write the query in the command (gh api graphql -f query='...') and pass its values as fields (-F name=value, -F name=@file); a shell variable is fine inside a read query ({...} or query ...), never inside a mutation; merging a PR through the API is human-only"
check_gh_graphql_query() {
  local i=0 n=${#GHW[@]} w v x letter open close head
  while [ "$i" -lt "$n" ]; do
    w="${GHW[i]}"
    v="" x=0 letter=""
    case "$w" in
      --input | --input=*)
        deny "gh api graphql --input reads the request from a file or stdin, which the guard does not read" "$GQL_NOT_WRITTEN_HINT"
        ;;
      --field | --raw-field)
        letter="${w#--}" v="${GHW[i + 1]-}" x="${GHX[i + 1]:-0}"
        i=$((i + 1))
        ;;
      --field=* | --raw-field=*)
        letter="${w%%=*}" letter="${letter#--}" v="${w#*=}" x="${GHX[i]}"
        ;;
      --?*) [[ "$GH_VALUE_GLOBAL$GH_VALUE_API" == *" $w "* ]] && i=$((i + 1)) ;;
      -?*)
        short_cluster "$w" "$GH_VALUE_GLOBAL$GH_VALUE_API"
        case "$SC_LETTER" in
          F | f)
            letter="$SC_LETTER"
            if [ "$SC_NEXT" -eq 1 ]; then v="${GHW[i + 1]-}" x="${GHX[i + 1]:-0}"; else v="$SC_VALUE" x="${GHX[i]}"; fi
            ;;
        esac
        [ "$SC_NEXT" -eq 1 ] && i=$((i + 1))
        ;;
    esac
    i=$((i + 1))
    [ -n "$letter" ] || continue
    [ "${v%%=*}" = query ] || continue
    v="${v#*=}"
    case "$letter" in
      F | field)
        case "$v" in
          @*) deny "gh api graphql -F query=@… reads the query from a file or stdin, which the guard does not read" "$GQL_NOT_WRITTEN_HINT" ;;
        esac
        ;;
    esac
    # Counted and cut byte by byte or with a regular expression (see TRAIL_BLANKS_RE): a query of
    # 60 KB took 5 s here in a UTF-8 locale (#302).
    gql_braces "$v"
    open="$GQL_OPEN" close="$GQL_CLOSE"
    [[ "$v" =~ $LEAD_BLANKS_RE ]]
    head="${v:${#BASH_REMATCH[0]}}"
    if [[ "$v" =~ $ONLY_BLANKS_RE ]] || [ "$open" -gt "$close" ] \
      || [[ "$v" == *__GUARD_SUBST__* || "$v" == *'`'* ]] \
      || { [ "$x" = 1 ] && [[ "$head" != '{'* && "$head" != query* ]]; }; then
      deny "gh api graphql with a query that is not written in the command ('query=${v//\$__GUARD_SUBST__/\$(…)}')" "$GQL_NOT_WRITTEN_HINT"
    fi
  done
  return 0
}
# gql_braces <query>: how many `{` and `}` it holds, in GQL_OPEN and GQL_CLOSE: the fields the text
# splits into at each, less one (a byte after it, so a last one counts too), as bare_text splits. Not
# by taking every other character out (`${1//[^\{]/}`): in a UTF-8 locale, and in the bash 3.2 of
# macOS in any, that costs the square of the text's length (20,000 `#` took 10 s; #302).
GQL_OPEN=0
GQL_CLOSE=0
LEAD_BLANKS_RE='^[[:space:]]*'
ONLY_BLANKS_RE='^[[:space:]]*$'
LEAD_TABS_RE=$'^\t*'
FIRST_LINE_RE=$'^[^\n]*'
gql_braces() {
  local IFS noglob=0
  local -a parts=()
  case "$-" in *f*) noglob=1 ;; esac
  set -f
  IFS='{'
  # shellcheck disable=SC2206 # splitting is the point; globbing is off
  parts=($1.)
  GQL_OPEN=$((${#parts[@]} - 1))
  IFS='}'
  # shellcheck disable=SC2206 # splitting is the point; globbing is off
  parts=($1.)
  GQL_CLOSE=$((${#parts[@]} - 1))
  [ "$noglob" -eq 1 ] || set +f
  return 0
}

# --- Merging belongs to GitHub Actions; the human-review label belongs to a human -------------
# The merge-when-green workflow merges a PR from a GitHub Actions job, with a GitHub App's token and
# after its own gates (the risk class, CI judged job by job, the integration branch green). A
# session reads that decision (`pr-merge.sh decide`, read-only) and, where its repository's policy
# lets an agent merge at all, merges with a plain `gh pr merge` once the gates are green; it never
# stands in for the job. So, in a session, whatever the policy says:
#   - `gh pr merge --admin` is denied: it merges past branch protection and the required checks
#     (in check_gh);
#   - the job's merge step, `pr-merge.sh merge` (`pr_merge.py merge` underneath), is denied
#     (check_mwg_merge);
#   - GITHUB_ACTIONS and MWG_WRITE_TOKEN_KIND are never assigned, exported or read into: they are
#     what tells that step it runs as the job with the App's token (check_ci_identity_*);
#   - `revision-humana` and `no-automerge` never come off a PR or an issue: the first is how a
#     change reaches a human reviewer, the second keeps merge-when-green from merging the PR on its
#     own, and only a human takes either off (owner_label_*, check_gh_api_labels). Adding them,
#     reading them and filtering by them are untouched, and so is removing any other label;
#   - branch protection and rulesets are not changed through the API (check_gh_api_protection):
#     they are what stops a merge or a push the gates above do not see, and they are the owner's.

# admin_value <value of --admin=…> <1 if the shell fills it in>: does it switch --admin on? gh
# reads it as a boolean; only a written false leaves it off.
admin_value() {
  [ "${2:-0}" = 1 ] && return 0
  case "$1" in
    false | False | FALSE | f | F | 0) return 1 ;;
  esac
  return 0
}

# The labels only a human takes off: the human-review label, and the one that keeps
# merge-when-green from merging a PR on its own (it skips a PR that carries it, and one that ever
# carried it). GitHub matches label names without regard to case, so the comparison ignores it too,
# and so do the blanks around a name. merge-when-green also skips `sin-revision-independiente` and
# `merge-freeze`; those two are not read here.
OWNER_LABEL="revision-humana"
OWNER_LABEL_GLOB='[Rr][Ee][Vv][Ii][Ss][Ii][Oo][Nn]-[Hh][Uu][Mm][Aa][Nn][Aa]'
NOAUTO_LABEL="no-automerge"
NOAUTO_LABEL_GLOB='[Nn][Oo]-[Aa][Uu][Tt][Oo][Mm][Ee][Rr][Gg][Ee]'
# Both, for a message about a label the guard cannot name.
OWNER_LABELS="${OWNER_LABEL} or ${NOAUTO_LABEL}"
# The one owner_label_word / owner_label_list matched last (OWNER_LABELS when it may be either).
HELD_LABEL=""

# owner_label_word <label name> <1 if the shell fills it in>: may it be one of those labels? One the
# shell fills in may be anything, so it may. Which one goes in HELD_LABEL. Braces make several names
# of one (`no-autom{e..e}rge`): each counts, and past the ones brace_words makes, it may be either.
owner_label_word() {
  local b
  if [ "${2:-0}" = 1 ]; then
    HELD_LABEL="$OWNER_LABELS"
    return 0
  fi
  brace_words "$1"
  for b in "${BRACE_OUT[@]}"; do
    owner_label_name "$b" && return 0
  done
  if [ "$BRACE_OVER" -eq 1 ]; then
    HELD_LABEL="$OWNER_LABELS"
    return 0
  fi
  return 1
}
# owner_label_name <one name>: is it one of those labels? A pattern (`no-automerg?`, `[n]o-automerge`)
# is a file name the shell puts in its place when one matches, in the directory where it runs, which
# the same command may have made (`touch no-automerge && …`): it counts when it matches either.
owner_label_name() {
  local v="$1" l
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  # shellcheck disable=SC2254 # the glob is the point: it matches the name in any case
  case "$v" in
    $OWNER_LABEL_GLOB)
      HELD_LABEL="$OWNER_LABEL"
      return 0
      ;;
    $NOAUTO_LABEL_GLOB)
      HELD_LABEL="$NOAUTO_LABEL"
      return 0
      ;;
  esac
  if [[ "$v" == *[\*\?\[]* ]]; then
    # Lowercased; the bash 3.2 of macOS has no ${v,,} (there it stopped the guard, and the command ran).
    if [ "${BASH_VERSINFO[0]}" -ge 4 ]; then
      v="${v,,}"
    else
      v="$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')"
    fi
    for l in "$OWNER_LABEL" "$NOAUTO_LABEL"; do
      # shellcheck disable=SC2053 # the pattern is the point
      if [[ "$l" == $v ]]; then
        HELD_LABEL="$l"
        return 0
      fi
    done
  fi
  return 1
}

# owner_label_list <value of --remove-label> <1 if the shell fills it in>: gh reads the value as a
# comma-separated list (CSV: a name may come in double quotes). Does any name in it, or anything the
# shell fills in, stand for one of those labels? Each name costs up to the length of the list, so
# 50,000 of them took more than 40 s: the judge's time limit holds inside the loop (#302).
owner_label_list() {
  local v e b
  if [ "${2:-0}" = 1 ]; then
    HELD_LABEL="$OWNER_LABELS"
    return 0
  fi
  # Brace expansion makes several words of one (`--remove-label={revision-humana,x}`): each counts.
  brace_words "$1"
  if [ "$BRACE_OVER" -eq 1 ]; then
    HELD_LABEL="$OWNER_LABELS"
    return 0
  fi
  for b in "${BRACE_OUT[@]}"; do
    v="${b//\"/}"
    while :; do
      check_deadline
      e="${v%%,*}"
      owner_label_word "$e" 0 && return 0
      [ "$e" = "$v" ] && break
      v="${v#*,}"
    done
  done
  return 1
}

# deny_owner_label <what the command does>: the reason names the label in HELD_LABEL (both when it
# is OWNER_LABELS), and says why that label stays.
deny_owner_label() {
  local why name="$HELD_LABEL"
  case "$name" in
    "$OWNER_LABEL") why="${OWNER_LABEL} is how a change reaches a human reviewer" ;;
    "$NOAUTO_LABEL") why="${NOAUTO_LABEL} keeps merge-when-green from merging the PR on its own" ;;
    *)
      name="<label>"
      why="${OWNER_LABEL} is how a change reaches a human reviewer and ${NOAUTO_LABEL} keeps merge-when-green from merging the PR on its own"
      ;;
  esac
  deny "$1. ${why}, and only a human takes it off" \
    "leave it on; if the reason for it no longer holds, say so in the PR's ## TL;DR and give the reviewer the command (gh pr edit <n> --repo <owner>/<name> --remove-label ${name}), in a body written with --body-file or a heredoc: a command written inside a quoted --body is read as one. Any other label comes off with gh pr edit <n> --remove-label <name>, the name written in the command"
}

# pct_decode <text>: <text> with each percent-escape decoded once, in PCT_DECODED; one that is not
# two hex digits stays as written. Cut at each `%` with IFS, as gql_braces counts: linear, in any
# bash and locale.
PCT_DECODED=""
pct_decode() {
  local LC_ALL=C
  local IFS=% piece h c noglob=0 first=1
  local -a pieces=()
  case "$-" in *f*) noglob=1 ;; esac
  set -f
  # shellcheck disable=SC2206 # splitting is the point; globbing is off
  pieces=($1.)
  [ "$noglob" -eq 1 ] || set +f
  PCT_DECODED=""
  for piece in "${pieces[@]}"; do
    check_deadline
    if [ "$first" -eq 1 ]; then
      PCT_DECODED="$piece"
      first=0
      continue
    fi
    h="${piece:0:2}"
    if [[ "$h" =~ ^[0-9A-Fa-f]{2}$ ]]; then
      printf -v c '%b' "\\x$h"
      PCT_DECODED+="$c${piece:2}"
    else
      PCT_DECODED+="%$piece"
    fi
  done
  PCT_DECODED="${PCT_DECODED%.}"
  return 0
}

# api_eol <gh api endpoint>: does it hold a line break (LF or CR), written or percent-encoded once or
# more (`%0a`, `%250a`, `%25%30%61`)? An escape whose digits the shell fills in or expands (`%$X`,
# `%0$X`, `%{0,1}a`, `{%0,x}a`, at any depth) may be one. Decoded up to API_EOL_PASSES times, while
# escapes are left; one still holding escapes after them is read as holding a line break. An
# endpoint with one is denied whole (api_path): the path GitHub routes it to is not one the guard
# reads, and no real request writes one (none in the transcripts of the 31 days to 2026-10-03).
API_EOL_PASSES=4
API_ESCAPE_RE='%[0-9A-Fa-f]{2}'
API_FILLED_ESCAPE_RE='%[0-9A-Fa-f]?[$`{},]'
api_eol() {
  local LC_ALL=C
  local t="$1" k
  for ((k = 0; k <= API_EOL_PASSES; k++)); do
    [[ "$t" == *[$'\n\r']* ]] && return 0
    [[ "$t" =~ $API_FILLED_ESCAPE_RE ]] && return 0
    [[ "$t" =~ $API_ESCAPE_RE ]] || return 1
    [ "$k" -lt "$API_EOL_PASSES" ] || return 0
    pct_decode "$t"
    t="$PCT_DECODED"
  done
  return 0
}

# api_endpoint_text <gh api endpoint>: the endpoint as its escapes are read, in API_EP_TEXT: each
# substitution (`$(…)`, `$((…))`, backquotes) written as `$_`, since its text never reaches the URL
# (its output may, as any part the shell fills in: see api_eol), and a `${name%pattern}` written as
# `$_{namepattern}`, since its `%` or `%%` is the shell's (`${sha%% *}`), not an escape; what its
# pattern holds is still read. At most API_EP_TEXT_MAX of each are rewritten; past them, the rest
# is read as written.
API_EP_TEXT=""
API_EP_TEXT_MAX=64
API_EP_SUBST_RE='^(.*)(\$\(\([^()]*\)\)|\$\([^()]*\)|`[^`]*`)(.*)$'
API_EP_PARAM_PCT_RE='^(.*)\$\{(#?[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?)%%?(.*)$'
api_endpoint_text() {
  local LC_ALL=C
  local t="$1" k=0
  if [[ "$t" == *'$('* || "$t" == *'`'* ]]; then
    while [ "$k" -lt "$API_EP_TEXT_MAX" ] && [[ "$t" =~ $API_EP_SUBST_RE ]]; do
      check_deadline
      t="${BASH_REMATCH[1]}\$_${BASH_REMATCH[3]}"
      k=$((k + 1))
    done
  fi
  k=0
  if [[ "$t" == *'${'*%* ]]; then
    while [ "$k" -lt "$API_EP_TEXT_MAX" ] && [[ "$t" =~ $API_EP_PARAM_PCT_RE ]]; do
      check_deadline
      t="${BASH_REMATCH[1]}\$_{${BASH_REMATCH[2]}${BASH_REMATCH[4]}"
      k=$((k + 1))
    done
  fi
  API_EP_TEXT="$t"
  return 0
}

# api_bad_escape <gh api endpoint>: does its path (before any query or fragment) hold a `%` without
# two hex digits after it? gh does not send such a path (Go's URL parser refuses it), and how to
# read it hangs on the locale (`%0é` was read as an escape in UTF-8 and not in C): an endpoint with
# one is denied (api_path), not guessed.
API_BAD_ESCAPE_RE='%([^0-9A-Fa-f]|[0-9A-Fa-f][^0-9A-Fa-f]|[0-9A-Fa-f]?$)'
api_bad_escape() {
  local LC_ALL=C
  local p="${1%%#*}"
  p="${p%%\?*}"
  [[ "$p" =~ $API_BAD_ESCAPE_RE ]]
}

# api_path <gh api endpoint>: the path the request reaches, in API_PATH: without scheme, host,
# query and fragment; percent-escapes decoded (an escaped `/` excepted, which stays part of its
# segment); `.` and `..` segments resolved, the way the server reads the path. An endpoint holding a
# line break, written or encoded (api_eol), or a malformed escape (api_bad_escape), is denied. Byte
# by byte (LC_ALL=C), the scheme and host cut with regular expressions (see TRAIL_BLANKS_RE). Each
# step of its loops costs up to the path's length, so a path written to repeat itself (5000 `%41`,
# 20000 segments) took 11 s: the judge's time limit holds inside them (#302).
API_PATH=""
API_EOL_FREE=""
api_path() {
  local LC_ALL=C p="$1" out="" h c seg
  local -a parts=() kept=()
  # The checks of one endpoint read it several times: the last one found free of line breaks and
  # malformed escapes is not read again.
  [ "$p" = "$API_EOL_FREE" ] || api_endpoint_text "$p"
  if [ "$p" != "$API_EOL_FREE" ] && api_eol "$API_EP_TEXT"; then
    deny "gh api with a line break in its endpoint, written, percent-encoded (%0a, %0d, or encoded again, %250a) or in an escape the shell fills in or expands (%\$X, %{0,1}a): GitHub decodes the path, and the one a line break makes it reach is not the one the guard reads" \
      "write the endpoint on one line and without encoded line breaks; text with line breaks goes in a field (-f body=..., --input), which gh encodes itself"
  fi
  if [ "$p" != "$API_EOL_FREE" ] && api_bad_escape "$API_EP_TEXT"; then
    deny "gh api with a malformed percent-escape in the path of its endpoint (a % without two hex digits after it): gh does not send that path as written, and the guard does not guess which one it is" \
      "write a literal % as %25, and each escape as % and two hex digits"
  fi
  API_EOL_FREE="$p"
  p="${p%%#*}"
  p="${p%%\?*}"
  case "$p" in
    *://*)
      [[ "$p" =~ '://'(.*)$ ]]
      p="${BASH_REMATCH[1]}"
      if [[ "$p" =~ /(.*)$ ]]; then p="${BASH_REMATCH[1]}"; else p=""; fi
      ;;
  esac
  while [[ "$p" == *%* ]]; do
    check_deadline
    out+="${p%%\%*}"
    p="${p#*%}"
    h="${p:0:2}"
    if [[ "$h" =~ ^[0-9A-Fa-f]{2}$ ]] && [[ "$h" != 2[Ff] ]] && [[ "$h" != 00 ]]; then
      printf -v c '%b' "\\x$h"
      out+="$c"
      p="${p:2}"
    else
      out+="%"
    fi
  done
  p="$out$p"
  words_of "$p" /
  parts=(${SPLIT_WORDS[@]+"${SPLIT_WORDS[@]}"})
  for seg in ${parts[@]+"${parts[@]}"}; do
    check_deadline
    case "$seg" in
      '' | .) ;;
      ..) [ "${#kept[@]}" -gt 0 ] && unset 'kept[${#kept[@]}-1]' ;;
      *) kept+=("$seg") ;;
    esac
  done
  API_PATH=""
  for seg in ${kept[@]+"${kept[@]}"}; do
    check_deadline
    API_PATH+="${API_PATH:+/}$seg"
  done
  # A trailing slash names the collection itself: kept as an empty last segment.
  [[ "$p" == */ ]] && API_PATH+="/"
  return 0
}

# The REST endpoints that take a label off: one label of an issue or PR (DELETE), all of them
# (DELETE, or PUT, which replaces them), the label itself in the repository (DELETE, or PATCH,
# which renames it), and an issue or PR edited with a `labels` field (PATCH, which replaces them).
# PRs carry their labels through the issues endpoints. GitHub takes POST for PATCH on these two
# (measured 2026-10-01: both answer as "update an issue" / "update a label"), and gh sends POST
# when no method is given but fields or --input are (`gh api repos/o/n/issues/5 -f 'labels[]=x'`).
# A method the shell fills in may be any. A body read with --input is not visible, except in the
# command itself (`echo '{"labels":[]}' | gh api … --input -`, a heredoc): one that names `labels`
# counts as a labels field.
API_ISSUE_LABELS_RE='(^|/)issues/[^/]+/labels(/(.*))?$'
API_REPO_LABEL_RE='(^|/)labels/([^/]+)$'
API_ISSUE_RE='(^|/)issues/[^/]+$'

# gh_api_request: the request a `gh api` call in GHW sends. API_METHOD is the method as GitHub gets
# it: GET, POST, PUT, PATCH, DELETE, OTHER, or ANY when the shell fills it in; without -X, gh sends
# POST when fields or --input are given and GET otherwise. API_KEYS holds the names of its fields
# (-f/-F/--field/--raw-field) and API_FIELDS the fields whole (`name=value`); API_INPUT is 1 when
# it reads a body with --input, and API_INPUT_FILE is 1 when that body comes from a file the guard
# does not read: a file name (`--input f.json`), one the shell fills in (`"$F"`, `$(…)`), a process
# substitution (`<(cat f.json)`), or stdin redirected from a file (`--input - < f.json`). Stdin
# otherwise (a pipe, a heredoc, a here-string) is judged by the text the command holds.
API_METHOD=""
API_INPUT=0
API_INPUT_FILE=0
API_KEYS=()
API_FIELDS=()
# api_input_source <value of --input>: sets API_INPUT_FILE, the redirection of stdin aside.
API_INPUT_STDIN=0
api_input_source() {
  case "$1" in
    - | /dev/stdin | /dev/fd/0 | /proc/self/fd/0) API_INPUT_STDIN=1 ;;
    '') ;;
    *) API_INPUT_FILE=1 ;;
  esac
  return 0
}
gh_api_request() {
  local i=0 n=${#GHW[@]} w method="" method_x=0 key params=0
  API_INPUT=0
  API_INPUT_FILE=0
  API_INPUT_STDIN=0
  API_KEYS=()
  API_FIELDS=()
  while [ "$i" -lt "$n" ]; do
    w="${GHW[i]}" key=""
    case "$w" in
      --) break ;;
      -X | --method)
        method="${GHW[i + 1]-}" method_x="${GHX[i + 1]:-0}"
        i=$((i + 1))
        ;;
      --method=*) method="${w#*=}" method_x="${GHX[i]}" ;;
      -f | -F | --field | --raw-field)
        key="${GHW[i + 1]-}" params=1
        i=$((i + 1))
        ;;
      --field=* | --raw-field=*) key="${w#*=}" params=1 ;;
      --input)
        API_INPUT=1
        api_input_source "${GHW[i + 1]-}"
        i=$((i + 1))
        ;;
      --input=*)
        API_INPUT=1
        api_input_source "${w#*=}"
        ;;
      --?*) [[ "$GH_VALUE_GLOBAL$GH_VALUE_API" == *" $w "* ]] && i=$((i + 1)) ;;
      -?*)
        short_cluster "$w" "$GH_VALUE_GLOBAL$GH_VALUE_API"
        case "$SC_LETTER" in
          X)
            if [ "$SC_NEXT" -eq 1 ]; then method="${GHW[i + 1]-}" method_x="${GHX[i + 1]:-0}"; else method="$SC_VALUE" method_x="${GHX[i]}"; fi
            ;;
          f | F)
            if [ "$SC_NEXT" -eq 1 ]; then key="${GHW[i + 1]-}"; else key="$SC_VALUE"; fi
            params=1
            ;;
        esac
        [ "$SC_NEXT" -eq 1 ] && i=$((i + 1))
        ;;
    esac
    if [ -n "$key" ]; then
      API_KEYS+=("${key%%=*}")
      API_FIELDS+=("$key")
    fi
    i=$((i + 1))
  done
  # Stdin redirected from a file (`< f.json`, `0<f.json`; not a heredoc, a here-string or `<&`), in
  # its words or anywhere in the command (see stdin_unread).
  if [ "$API_INPUT_STDIN" -eq 1 ]; then
    for w in ${GHW[@]+"${GHW[@]}"}; do
      case "$w" in
        '<' | '0<' | '<'[!'<(&']* | '0<'[!'<(&']*) API_INPUT_FILE=1 ;;
      esac
    done
    [ "$API_INPUT_FILE" -eq 1 ] || ! stdin_unread || API_INPUT_FILE=1
  fi
  case "$method" in
    '') if [ "$params" -eq 1 ] || [ "$API_INPUT" -eq 1 ]; then API_METHOD=POST; else API_METHOD=GET; fi ;;
    [Gg][Ee][Tt]) API_METHOD=GET ;;
    [Dd][Ee][Ll][Ee][Tt][Ee]) API_METHOD=DELETE ;;
    [Pp][Uu][Tt]) API_METHOD=PUT ;;
    [Pp][Aa][Tt][Cc][Hh]) API_METHOD=PATCH ;;
    [Pp][Oo][Ss][Tt]) API_METHOD=POST ;;
    *) API_METHOD=OTHER ;;
  esac
  [ "$method_x" = 1 ] && API_METHOD=ANY
  return 0
}

# filled_in <word> <1 if the shell fills part of the command word in>: does <word> hold a part the
# shell fills in ($NAME, `…`) or xargs' or parallel's replace string (`{}`)?
filled_in() {
  [ "${2:-0}" = 1 ] || return 1
  [[ "$1" == *'$'* || "$1" == *'`'* ]] && return 0
  [ -n "$PFX_REPL" ] && [[ "$1" == *"$PFX_REPL"* ]]
}

# Braces make several endpoints of one (`issues/5/labels/no-autom{e..e}rge`): each is judged.
# stdin_unread: may stdin hold text the command does not show? Called on a gh api call whose words
# send no file to its stdin (the caller looked), and that reads its body from there (`--input -`).
#   - Its own here-string or heredoc is its stdin, whatever stands around it: unread when the
#     here-string holds an expansion outside single quotes (`<<< "$(cat f)"`, `<<< $(<f)`,
#     `<<< "$B"`), or when the heredoc's delimiter is not quoted and a body holds one.
#   - A pipe into it (`echo '{…}' | gh api …`) is its stdin: not read here, the text it carries is
#     judged as the command shows it. Told by the segment's place in the command (RAW_COMMAND): a
#     `|` right before every place it stands.
#   - Otherwise read in the whole command, since a redirection may stand in front of the command, on
#     a group, a subshell or a loop around it, or on exec (`< f gh api …`, `{ gh api …; } < f`,
#     `exec 0<f; gh api …`): an input redirection from a file, `<>`, or `< <(…)`; a here-string or
#     heredoc as above. Broad on purpose: a `<` inside a quoted argument counts too.
# Until 2026-10-03 the whole command was read in every case, and a `<` anywhere (in the quoted body
# of the call's own heredoc, a `wc -l < f` further on, the `done < ids.txt` of the loop around a
# pipe into it) took a body the guard reads for one it does not (found verifying #299).
STDIN_FILE_RE='(^|[^<])[0-9]*<([^<(&]|$)'
HEREDOC_OP_RE="(^|[^<])<<(-?)[[:space:]]*([\"'\\\\]?)([A-Za-z_][A-Za-z0-9_]*)"
OWN_HEREDOC_RE="(^|[[:space:]])0?<<(-?)[[:space:]]*([\"'\\\\]?)([A-Za-z_][A-Za-z0-9_-]*)"
OWN_HERESTRING_RE='(^|[[:space:]])0?<<<'
stdin_unread() {
  local line w delim="" strip=0 expand=0 k own=""
  local -a lines=()
  raw_command
  for ((k = 0; k < ${#GHW[@]}; k++)); do
    w="${GHW[k]}"
    case "$w" in
      '<<<' | 0'<<<')
        own=hs
        [ "${GHX[k + 1]:-1}" = 1 ] && return 0
        ;;
      '<<<'* | 0'<<<'*)
        own=hs
        [ "${GHX[k]}" = 1 ] && return 0
        ;;
      '<<'* | 0'<<'*) own=hd ;;
    esac
  done
  # GHW has the quotes taken out: the segment, as written, says whether that word is a redirection
  # (a blank before it, not a quote) and whether the heredoc's delimiter is quoted (then its body is
  # what the command shows). An unquoted one is read as below, with the rest.
  case "$own" in
    hs) [[ "${seg-}" =~ $OWN_HERESTRING_RE ]] && return 1 ;;
    hd)
      if [[ "${seg-}" =~ $OWN_HEREDOC_RE ]]; then
        [ -n "${BASH_REMATCH[3]}" ] && return 1
      else
        own=""
      fi
      ;;
  esac
  [ "$own" != hs ] || own=""
  [ -n "$own" ] || ! stdin_piped || return 1
  [ "$own" = hd ] || [[ ! "$RAW_COMMAND" =~ $STDIN_FILE_RE ]] || return 0
  ! herestring_unread || return 0
  mapfile_of "$RAW_COMMAND"
  lines=(${MAPPED_LINES[@]+"${MAPPED_LINES[@]}"})
  for line in ${lines[@]+"${lines[@]}"}; do
    check_deadline
    if [ -n "$delim" ]; then
      # The tabs off the front with a regular expression (see TRAIL_BLANKS_RE): 200,000 of them
      # took 57 s with `${line#"${line%%[!$'\t']*}"}` (#302).
      if [ "$strip" -eq 1 ]; then
        [[ "$line" =~ $LEAD_TABS_RE ]]
        line="${line:${#BASH_REMATCH[0]}}"
      fi
      if [ "$line" = "$delim" ]; then
        delim=""
        continue
      fi
      [ "$expand" -eq 1 ] && [[ "$line" == *'$'* || "$line" == *'`'* ]] && return 0
      continue
    fi
    if [[ "$line" =~ $HEREDOC_OP_RE ]]; then
      delim="${BASH_REMATCH[4]}"
      strip=0 expand=1
      [ "${BASH_REMATCH[2]}" = - ] && strip=1
      [ -n "${BASH_REMATCH[3]}" ] && expand=0
    fi
  done
  return 1
}
# herestring_unread: does a here-string anywhere in the command (RAW_COMMAND) hand stdin what the
# shell fills in (a `$` or a backtick in its line, the word not single-quoted)? Cut byte by byte
# (LC_ALL=C) with regular expressions (see TRAIL_BLANKS_RE): `${w#*<<<}` and taking the blanks off
# the front cost the square of the length before the cut (a here-string after 200 KB took 15 s, one
# behind 200,000 blanks more than 60, #302). Byte by byte, the blanks taken off the front are the
# ASCII ones, the only ones the shell splits words on.
herestring_unread() {
  local LC_ALL=C w="$RAW_COMMAND" line
  while [[ "$w" =~ '<<<'(.*)$ ]]; do
    check_deadline
    w="${BASH_REMATCH[1]}"
    [[ "$w" =~ $LEAD_BLANKS_RE ]]
    line="${w:${#BASH_REMATCH[0]}}"
    [[ "$line" =~ $FIRST_LINE_RE ]]
    line="${BASH_REMATCH[0]}"
    [[ "$line" == \'* ]] && continue
    [[ "$line" == *'$'* || "$line" == *'`'* ]] && return 0
  done
  return 1
}

# stdin_piped: is the segment being judged (check_segment's seg) fed by a pipe wherever it stands
# in the command? Its text found in RAW_COMMAND with `|` (or `|&`) before it, past blanks, every
# time, and at least as many times as the extractor sent it (segs_holding): one the extractor
# rewrote (a line joined, a substitution masked) is not found as written, and a pipe into a decoy
# with the same text does not speak for it.
# Not piped, the stricter reading, past what the guard spends looking for it (as_written_fits,
# AS_WRITTEN_PLACES_MAX). Until 2026-10-03 each place cost the square of the length before it
# (`${rest#*"$s"}`), and 500 piped copies of one call ran past ten seconds (#302): each match now
# takes what follows it too (`(.*)$`, see TRAIL_BLANKS_RE).
stdin_piped() {
  local LC_ALL=C s="${seg-}" rest="$RAW_COMMAND" before found=0
  [ -n "$s" ] || return 1
  as_written_fits "$s" || return 1
  while [[ "$rest" =~ "$s"(.*)$ ]]; do
    check_deadline
    [ "$found" -lt "$AS_WRITTEN_PLACES_MAX" ] || return 1
    before="${rest:0:${#rest}-${#BASH_REMATCH[0]}}"
    rest="${BASH_REMATCH[1]}"
    [[ "$before" =~ $TRAIL_BLANKS_RE ]]
    before="${before:0:${#before}-${#BASH_REMATCH[0]}}"
    case "$before" in
      *'||') return 1 ;;
      *'|' | *'|&') found=$((found + 1)) ;;
      *) return 1 ;;
    esac
  done
  segs_holding "$s"
  [ "$found" -ge 1 ] && [ "$found" -ge "$SEGS_HOLDING" ]
}

# segs_holding <text>: how many of the segments the extractor sent are the text, the copies of quoted
# spans (\v) aside, in SEGS_HOLDING.
SEGS_HOLDING=0
segs_holding() {
  local line
  SEGS_HOLDING=0
  segment_lines
  for line in ${SEGMENT_LINES[@]+"${SEGMENT_LINES[@]}"}; do
    case "$line" in $'\v'* | $'\x01'*) continue ;; esac
    [[ "$line" == $'\t'* ]] && line="${line:1}"
    [ "$line" = "$1" ] && SEGS_HOLDING=$((SEGS_HOLDING + 1))
  done
  return 0
}

# An endpoint whose braces make more paths than brace_words reads, or that is longer than it expands,
# may be any path: a label, a long-lived branch, branch protection. Written with any method that
# writes, it is denied (#306); no real endpoint comes near either limit.
check_gh_api_braces() {
  [ -n "$1" ] || return 0
  brace_words "$1"
  [ "$BRACE_OVER" -eq 1 ] || return 0
  gh_api_request
  case "$API_METHOD" in
    POST | PUT | PATCH | DELETE | ANY) ;;
    *) return 0 ;;
  esac
  deny "gh api ${API_METHOD/ANY/<method>} with an endpoint whose braces make more paths than the guard reads, which may write a label, a long-lived branch or branch protection" \
    "write the endpoint in full, one call per path"
}

check_gh_api_labels() {
  local e
  [ -n "$1" ] || return 0
  brace_words "$1"
  for e in "${BRACE_OUT[@]}"; do check_gh_api_labels_one "$e" "${2:-0}"; done
  return 0
}
check_gh_api_labels_one() {
  local ep="$1" ep_x="${2:-0}" key m name name_x fields=0
  [ -n "$ep" ] || return 0
  gh_api_request
  m="$API_METHOD"
  # A field name the shell fills in may be `labels`.
  for key in ${API_KEYS[@]+"${API_KEYS[@]}"}; do
    [[ "$key" == labels* || "$key" == *'$'* || "$key" == *'`'* ]] && fields=1
  done
  api_path "$ep"
  if [[ "$API_PATH" =~ $API_ISSUE_LABELS_RE ]]; then
    if [ -n "${BASH_REMATCH[3]}" ]; then
      name="${BASH_REMATCH[3]}"
      name_x=0
      filled_in "$name" "$ep_x" && name_x=1
      case "$m" in
        DELETE | ANY)
          if owner_label_word "$name" "$name_x"; then
            deny_owner_label "gh api ${m/ANY/<method>} ${ep}: takes the label '${name}' off an issue or PR"
          fi
          ;;
      esac
    else
      case "$m" in
        DELETE | PUT | ANY)
          HELD_LABEL="$OWNER_LABELS"
          deny_owner_label "gh api ${m/ANY/<method>} ${ep}: clears or replaces every label of an issue or PR, ${OWNER_LABEL} and ${NOAUTO_LABEL} included"
          ;;
      esac
    fi
  elif [[ "$API_PATH" =~ $API_REPO_LABEL_RE ]]; then
    name="${BASH_REMATCH[2]}"
    name_x=0
    filled_in "$name" "$ep_x" && name_x=1
    case "$m" in
      DELETE | PATCH | POST | ANY)
        if owner_label_word "$name" "$name_x"; then
          deny_owner_label "gh api ${m/ANY/<method>} ${ep}: deletes or renames the repository's label '${name}'"
        fi
        ;;
    esac
  elif [[ "$API_PATH" =~ $API_ISSUE_RE ]]; then
    case "$m" in
      PATCH | POST | ANY)
        HELD_LABEL="$OWNER_LABELS"
        # A body read from a file is not in front of the guard, so the path decides: it may carry
        # a labels field like any other.
        if [ "$fields" -eq 0 ] && [ "$API_INPUT_FILE" -eq 1 ]; then
          deny "gh api ${m/ANY/<method>} ${ep} --input <file>: edits the issue or PR with a body read from a file (or from stdin the shell fills from a file or an expansion), which the guard does not read, and a labels field in it would replace every label, ${OWNER_LABEL} and ${NOAUTO_LABEL} included (only a human takes those off)" \
            "write the fields in the command (gh api -X PATCH ${ep} -f title=… -F body=@<file>), or use gh pr edit / gh issue edit (--body-file <file>, --add-label <name>)"
        fi
        if [ "$fields" -eq 0 ] && [ "$API_INPUT" -eq 1 ]; then
          raw_command
          [[ "$RAW_COMMAND" == *labels* ]] && fields=1
        fi
        if [ "$fields" -eq 1 ]; then
          deny_owner_label "gh api ${m/ANY/<method>} ${ep} with a labels field: replaces every label of the issue or PR, ${OWNER_LABEL} and ${NOAUTO_LABEL} included"
        fi
        ;;
    esac
  fi
  return 0
}

# A long-lived branch deleted or moved through the REST API never reaches git push, where the guard
# reads those rules: DELETE, PATCH, PUT and POST (which gh sends when fields are given,
# `-F force=true -f sha=…`) on git/refs/heads/<branch>, the branch being long-lived
# (is_long_lived_branch: the list `git branch -D` and `git push --delete` use). Until 2026-10-02
# `gh api -X DELETE …/git/refs/heads/develop` passed, and no branch protection behind the guard can
# be assumed (see the header). Reading a ref passes, and so do the real cleanups of the 31 days to
# that date: DELETE of a finished work branch, PATCH with force of the agent's own one, and POST to
# git/refs, which creates a branch or a tag and fails when it exists. A branch the shell fills in is
# not judged, as for `git push --delete "$b"`; one its braces spell (`d{e..e}velop`) or whose slash
# is escaped (`heads%2Fdevelop`) is read as GitHub gets it.
# Two more doors of the REST API do the same (found 2026-10-02, verifying this change; no real
# command of the 31 days uses them): renaming the branch (POST branches/<branch>/rename: the
# long-lived name is gone) and writing a file through the contents endpoint (PUT or DELETE
# contents/<path>), which commits onto the branch its `branch` field names, or onto the default
# branch without one: a push to main without git push.
API_REF_RE='(^|/)git/refs?/heads/(.+)$'
API_RENAME_RE='(^|/)branches/(.+)/rename$'
API_CONTENTS_RE='(^|/)(repos/[^/]+/[^/]+|repositories/[^/]+)/contents(/.*)?$'
check_gh_api_refs() {
  local ep="$1" ep_x="${2:-0}" p b w f fb="" fb_set=0 why
  [ -n "$ep" ] || return 0
  api_path "$ep"
  p="${API_PATH//%2[Ff]//}"
  if [[ "$p" =~ $API_CONTENTS_RE ]]; then
    gh_api_request
    case "$API_METHOD" in
      PUT | DELETE | ANY) ;;
      *) return 0 ;;
    esac
    for f in ${API_FIELDS[@]+"${API_FIELDS[@]}"}; do
      [[ "$f" == branch=* ]] && fb="${f#branch=}" fb_set=1
    done
    if [ "$fb_set" -eq 0 ]; then
      why="it names no branch field"
      [ "$API_INPUT" -eq 1 ] && why="its branch, if any, is in a body read with --input, which the guard does not see"
      deny "gh api ${API_METHOD/ANY/<method>} ${ep}: writes a commit onto the repository's default branch when no branch is given, and ${why}; that is past the rules git push follows" \
        "commit in your branch's worktree and push it (git push), then open a PR; a long-lived branch moves by a merged PR"
    fi
    [[ "$fb" == *'$'* || "$fb" == *'`'* ]] && return 0
    brace_words "$fb"
    if [ "$BRACE_OVER" -eq 1 ]; then
      deny "gh api ${API_METHOD/ANY/<method>} ${ep}: writes a commit onto a branch whose braces make more names than the guard reads, which may be a long-lived branch" \
        "commit in your branch's worktree and push it (git push), then open a PR; a long-lived branch moves by a merged PR"
    fi
    for w in "${BRACE_OUT[@]}"; do
      is_long_lived_branch "$w" || continue
      deny "gh api ${API_METHOD/ANY/<method>} ${ep}: writes a commit onto the long-lived branch '${w}', past the rules git push follows" \
        "commit in your branch's worktree and push it (git push), then open a PR; a long-lived branch moves by a merged PR"
    done
    return 0
  fi
  if [[ "$p" =~ $API_REF_RE || "$p" =~ $API_RENAME_RE ]]; then
    b="${BASH_REMATCH[2]%/}"
  else
    return 0
  fi
  [ "$ep_x" = 1 ] && [[ "$b" == *'$'* || "$b" == *'`'* ]] && return 0
  gh_api_request
  case "$API_METHOD" in
    DELETE | PATCH | PUT | POST | ANY) ;;
    *) return 0 ;;
  esac
  brace_words "$b"
  for w in "${BRACE_OUT[@]}"; do
    is_long_lived_branch "$w" || continue
    deny "gh api ${API_METHOD/ANY/<method>} ${ep}: deletes, renames or moves the long-lived branch '${w}' on GitHub, past the rules git push follows" \
      "a long-lived branch moves by a merged PR, and only a human deletes, renames or rewrites it; your own branch is updated with git push (--force-with-lease after a rebase)"
  done
  return 0
}

# Branch protection and rulesets are what stops, on GitHub's side, a push or a merge the guard does
# not see; where a repository has them, an agent that lowers them has opened every door at once. So
# no write reaches them through the REST API (and the GraphQL twins are denied in check_gh):
#   - repos/<o>/<r>/branches/<branch>/protection and every subresource under it
#     (required_status_checks and its contexts, required_pull_request_reviews, enforce_admins,
#     required_signatures, restrictions and its apps/teams/users), whatever the branch: DELETE
#     takes the protection or the rule off, PUT replaces it whole, PATCH and POST change it;
#   - the rulesets of a repository, an organization or an enterprise (…/rulesets[/<id>]): POST
#     creates one, PUT changes it, DELETE removes it.
# The path decides, not the body: one read from a file (`--input f.json`) is not in front of the
# guard, and any write there is the owner's call, raising it too (a PUT replaces the whole
# protection, and the guard cannot tell from it whether it raises or lowers). Reading passes: GET,
# and gh's default without fields or --input; `-X GET` with fields too. With fields and no -X, gh
# sends POST. A method the shell fills in (`-X "$M"`) may be any. No real command of the 31 days to
# 2026-10-03 writes there; reading the protection and the rulesets is common, and passes.
PROTECTION_HINT="leave branch protection and rulesets as they are; read them with gh api <path> (GET, or -X GET with fields), and if they need to change, say so in the PR's ## TL;DR or an issue with the exact command, for the repository owner to run (write that body with --body-file or a heredoc: a command written inside a quoted --body is read as one)"
# The repository part is <owner>/<name>, one word the shell fills in with both (`repos/$R/…`), or
# the repository's id: GitHub serves the same resources under repositories/<id>/… (measured
# 2026-10-03: repositories/<id>/rulesets answers 200, and …/branches/<b>/protection answers as
# repos/<o>/<r>/… does).
API_PROTECTION_RE='(^|/)(repos/([^/]+/[^/]+|[^/]*[$][^/]*)|repositories/[^/]+)/branches/(.+)/protection(/.*)?$'
API_RULESETS_RE='(^|/)(repos/([^/]+/[^/]+|[^/]*[$][^/]*)|repositories/[^/]+|orgs/[^/]+|enterprises/[^/]+)/rulesets(/.*)?$'
# protection_path <path>: is it branch protection or rulesets? What it is goes in API_TARGET.
API_TARGET=""
protection_path() {
  if [[ "$1" =~ $API_PROTECTION_RE ]]; then
    API_TARGET="the branch protection of '${BASH_REMATCH[4]}'"
    return 0
  fi
  if [[ "$1" =~ $API_RULESETS_RE ]]; then
    API_TARGET="the rulesets of ${BASH_REMATCH[2]#repos/}"
    return 0
  fi
  return 1
}
# seg_glob <one segment of a path>: the segment as a pattern, in SEG_GLOB: each part the shell fills
# in (${…}, $NAME, $1, `…`, xargs' or parallel's replace string) becomes `*`; a pattern of its own
# (`prot*`) stays one, since the shell may put a file name in its place.
SEG_GLOB=""
seg_glob() {
  local s="$1" g=""
  [ -n "$PFX_REPL" ] && s="${s//"$PFX_REPL"/\$}"
  while [[ "$s" =~ $SEG_FILLED_RE ]]; do
    g+="${BASH_REMATCH[1]}*"
    s="${BASH_REMATCH[3]}"
  done
  SEG_GLOB="$g$s"
}
SEG_FILLED_RE='^([^$`]*)(\$\{[^}]*\}|\$[A-Za-z_][A-Za-z0-9_]*|\$[0-9@*#?$!-]|`[^`]*`?|\$)(.*)$'
# api_path_variants <path>: the paths it may stand for when the shell fills in part of it, in
# API_VARIANTS (API_VARIANTS_OVER is 1 past 256 of them). A segment the shell fills in whole may be
# any word: here, branches/<x>, protection or rulesets (`repos/o/r/$Y/protection`). Right after
# repos/ it is the owner and the name (`repos/$R/rulesets`), unless the next one is filled in too:
# two in a row (`repos/$OWNER/$REPO/…`) are the owner and the name. Read as the owner and the name
# together, the second was free to be rulesets, and every write to repos/$OWNER/$REPO/… was denied as
# one to the rulesets (found 2026-10-03, verifying #299: a commit through the API from a loop over
# the fleet's repositories). One filled in in part (`rule$S`, `prot*`) may be each of protection,
# rulesets and branches its pattern matches, or another word.
API_VARIANTS=()
API_VARIANTS_OVER=0
api_path_variants() {
  local seg v o k i n
  local -a parts=() lit=() globs=() cur=("") next=() alts=()
  API_VARIANTS=() API_VARIANTS_OVER=0
  words_of "$1" /
  parts=(${SPLIT_WORDS[@]+"${SPLIT_WORDS[@]}"})
  n=${#parts[@]}
  for ((i = 0; i < n; i++)); do
    check_deadline
    seg_glob "${parts[i]}"
    globs[i]="$SEG_GLOB"
    lit[i]=0
    [ "$SEG_GLOB" = "${parts[i]}" ] && [[ "${parts[i]}" != *[\*\?\[]* ]] && lit[i]=1
  done
  for ((i = 0; i < n; i++)); do
    check_deadline
    seg="${parts[i]}"
    if [ "${lit[i]}" -eq 1 ]; then
      alts=("$seg")
    elif [ "$i" -ge 1 ] && [ "${parts[i - 1]}" = repos ]; then
      alts=("x/x")
      [ "$((i + 1))" -lt "$n" ] && [ "${lit[i + 1]}" -eq 0 ] && alts=(x)
    elif [ "$i" -ge 2 ] && [ "${parts[i - 2]}" = repos ]; then
      alts=(x)
    elif [ -z "${globs[i]//\*/}" ]; then
      alts=(x branches/x protection rulesets)
    else
      alts=(x)
      for k in protection rulesets branches; do
        # shellcheck disable=SC2053 # the pattern is the point
        [[ "$k" == ${globs[i]} ]] && alts+=("$k")
      done
    fi
    next=()
    for v in "${cur[@]}"; do
      for o in "${alts[@]}"; do next+=("${v:+$v/}$o"); done
    done
    if [ "${#next[@]}" -gt 256 ]; then
      API_VARIANTS_OVER=1
      return 0
    fi
    cur=("${next[@]}")
  done
  API_VARIANTS=("${cur[@]}")
}
# api_protection_target <endpoint> <1 if the shell fills part of it in>: does a request to it reach
# branch protection or rulesets? What it writes goes in API_TARGET.
api_protection_target() {
  local p v
  api_path "$1"
  p="${API_PATH//%2[Ff]//}"
  protection_path "$p" && return 0
  [ "${2:-0}" = 1 ] || [[ "$p" == *[\*\?\[]* ]] || return 1
  api_path_variants "$p"
  if [ "$API_VARIANTS_OVER" -eq 1 ]; then
    API_TARGET="a path the shell fills in in too many places to read, which may be branch protection or rulesets"
    return 0
  fi
  for v in ${API_VARIANTS[@]+"${API_VARIANTS[@]}"}; do
    if protection_path "$v"; then
      API_TARGET="${API_TARGET} (the shell fills in part of the path, which may make it ${v})"
      return 0
    fi
  done
  return 1
}
# Braces make several endpoints of one (`prot{e..e}ction`, `rule{s..s}ets`): each counts, and past
# the ones brace_words makes, it may be any. A part the shell fills in, or a pattern, may be what
# makes it branch protection or rulesets (`branches/main/$X`, `rule$S/1`, `branches/main/{}` behind
# xargs -I{}): see api_path_variants. The endpoint filled in whole (`gh api -X DELETE "$EP"`) is
# not read.
check_gh_api_protection() {
  local ep="$1" ep_x="${2:-0}" e what="" body=""
  [ -n "$ep" ] || return 0
  brace_words "$ep"
  for e in "${BRACE_OUT[@]}"; do
    if api_protection_target "$e" "$ep_x"; then
      what="$API_TARGET"
      break
    fi
  done
  if [ -z "$what" ] && [ "$BRACE_OVER" -eq 1 ]; then
    what="a path whose braces make more endpoints than the guard reads, which may be branch protection or rulesets"
  fi
  [ -n "$what" ] || return 0
  gh_api_request
  case "$API_METHOD" in
    POST | PUT | PATCH | DELETE | ANY) ;;
    *) return 0 ;;
  esac
  [ "$API_INPUT" -eq 1 ] && body=" (its body comes from --input, which the guard does not read: the path alone decides)"
  deny "gh api ${API_METHOD/ANY/<method>} ${ep}: writes ${what}${body}; branch protection and rulesets are the repository owner's settings, and lowering them opens every push and merge they hold back" \
    "$PROTECTION_HINT"
}

# The GraphQL document a `gh api graphql` call in GHW sends, as GraphQL reads it, in GQL_DOC: the
# values of its query fields, with string values taken out (a mutation named inside one is not one). Exit 1 when the guard cannot read it all (a field the shell fills in, one read from a
# file, --input): the caller reads the whole command then, as before.
GQL_DOC=""
gql_document() {
  local i=0 n=${#GHW[@]} w v x letter
  GQL_DOC=""
  while [ "$i" -lt "$n" ]; do
    w="${GHW[i]}" v="" x=0 letter=""
    case "$w" in
      --input | --input=*) return 1 ;;
      -f | -F | --field | --raw-field)
        letter="$w" v="${GHW[i + 1]-}" x="${GHX[i + 1]:-0}"
        i=$((i + 1))
        ;;
      --field=* | --raw-field=*) letter="${w%%=*}" v="${w#*=}" x="${GHX[i]}" ;;
      --?*) [[ "$GH_VALUE_GLOBAL$GH_VALUE_API" == *" $w "* ]] && i=$((i + 1)) ;;
      -?*)
        short_cluster "$w" "$GH_VALUE_GLOBAL$GH_VALUE_API"
        case "$SC_LETTER" in
          F | f)
            letter="-$SC_LETTER"
            if [ "$SC_NEXT" -eq 1 ]; then v="${GHW[i + 1]-}" x="${GHX[i + 1]:-0}"; else v="$SC_VALUE" x="${GHX[i]}"; fi
            ;;
        esac
        [ "$SC_NEXT" -eq 1 ] && i=$((i + 1))
        ;;
    esac
    i=$((i + 1))
    [ -n "$letter" ] || continue
    [ "$x" = 1 ] && return 1
    [ "${v%%=*}" = query ] || continue
    v="${v#*=}"
    case "$letter" in -F | --field) [[ "$v" == @* ]] && return 1 ;; esac
    gql_value "$v"
  done
  return 0
}
# gql_value <the value of a query field>: added to GQL_DOC as GraphQL reads it (gql_strip). A comment
# (`#`) runs to the end of its line, and the segment the guard reads has its lines joined (see the
# extractor), so a value that holds a `#` is read with its lines from the command as written
# (RAW_COMMAND): inside each place the segment stands (raw_regex: a blank of the segment may be a
# newline there), the value, and all of them go in. Until 2026-10-03 such a value was read whole, and
# a read query whose comment named a protection mutation was denied as that mutation (found
# verifying #299). Where the segment or the value cannot be found as written (a line joined, a shell
# escape the segment took out), or finding it would cost more than the guard spends on it
# (as_written_fits, AS_WRITTEN_PLACES_MAX): the value whole, nothing taken out of it, as before. Whole
# is the stricter reading: it holds every mutation name the value holds.
gql_value() {
  local LC_ALL=C v="$1" sre vre rest r m mrest doc="" places=0 found=0 ok=1
  if [[ "$v" != *'#'* ]]; then
    gql_strip "$v" 0
    GQL_DOC+="$GQL_STRIPPED"$'\n'
    return 0
  fi
  raw_command
  if [ -z "${seg-}" ] || ! as_written_fits "$seg"; then
    GQL_DOC+="$v"$'\n'
    return 0
  fi
  raw_regex "$seg"
  sre="$RAW_RE"
  raw_regex "$v"
  vre="$RAW_RE"
  # Each match takes what follows it too (`(.*)$`, see TRAIL_BLANKS_RE): cutting the place off with
  # `${rest#*"$r"}` costs the square of the length before it (a 5000-`#` value took 42 s, #302).
  rest="$RAW_COMMAND"
  while [[ "$rest" =~ $sre(.*)$ ]]; do
    check_deadline
    places=$((places + 1))
    if [ "$places" -gt "$AS_WRITTEN_PLACES_MAX" ]; then
      ok=0
      break
    fi
    rest="${BASH_REMATCH[1]}"
    r="${BASH_REMATCH[0]:0:${#BASH_REMATCH[0]}-${#rest}}"
    [[ "$r" =~ $vre ]] || ok=0
    mrest="$r"
    while [[ "$mrest" =~ $vre(.*)$ ]]; do
      check_deadline
      found=$((found + 1))
      if [ "$found" -gt "$AS_WRITTEN_PLACES_MAX" ]; then
        ok=0
        break 2
      fi
      mrest="${BASH_REMATCH[1]}"
      m="${BASH_REMATCH[0]:0:${#BASH_REMATCH[0]}-${#mrest}}"
      gql_strip "$m" 1
      doc+="$GQL_STRIPPED"$'\n'
    done
  done
  if [ "$places" -ge 1 ] && [ "$ok" -eq 1 ]; then GQL_DOC+="$doc"; else GQL_DOC+="$v"$'\n'; fi
  return 0
}
# raw_regex <text of a segment>: a regular expression that finds it in RAW_COMMAND, in RAW_RE: each
# character itself (the ones a regular expression reads as operators, behind a backslash), and each
# blank any blank (the extractor writes a newline as a blank). Byte by byte (LC_ALL=C), like the
# callers' matching. Built with replacements, not character by character: each `${t:k:1}` copies the
# whole text, and a loop of them grows with the square of its length. Each replacement comes from a
# variable, unquoted, with patsub_replacement off (bash 5.2 reads a `\` or `&` in it): the bash 3.2
# of macOS keeps the double quotes of a quoted one in the text, so a value with a blank or any of
# those characters was never found, and was read whole.
RAW_RE=""
raw_regex() {
  local LC_ALL=C t="$1" c rep sp='[[:space:]]' psr=0
  shopt -q patsub_replacement 2>/dev/null && psr=1 && shopt -u patsub_replacement
  for c in '\' . '[' ']' '(' ')' '*' + '?' '{' '}' '|' '^' '$'; do
    rep="\\$c"
    t="${t//"$c"/$rep}"
  done
  RAW_RE="${t// /$sp}"
  [ "$psr" -eq 0 ] || shopt -s patsub_replacement
  return 0
}
# How much work the guard spends finding a text where it stands in the command as written
# (RAW_COMMAND: gql_value, stdin_piped). Looking for a text costs up to its length times the
# command's, and a text written to repeat itself takes that much (#302: a GraphQL value of 5000 `#`
# took 42 s, and 20000 more than 300, past every hook's timeout, which lets the command run). So a
# text is looked for only while the two lengths multiplied stay within AS_WRITTEN_WORK_MAX (2^25),
# and in AS_WRITTEN_PLACES_MAX places at most; past either, the caller takes its stricter reading.
# Real commands: 268,185 at most over the 86,620 of the 31 days to 2026-10-03 (a 95-byte segment in a
# 2,823-byte command), and 2 places.
AS_WRITTEN_WORK_MAX=33554432
AS_WRITTEN_PLACES_MAX=64
# as_written_fits <text>: may it be looked for in RAW_COMMAND (read it first)?
as_written_fits() {
  local LC_ALL=C
  [ $((${#1} * ${#RAW_COMMAND})) -le "$AS_WRITTEN_WORK_MAX" ]
}
# These readers cut a long text with a regular expression: what comes before the first of a set of
# characters (`[[ $t =~ ^[^"#]* ]]`), the blanks it ends with (TRAIL_BLANKS_RE), or a text and all that
# follows it (`[[ $t =~ "<text>"(.*)$ ]]`, the rest in BASH_REMATCH[1]). Not with `${t#*<text>}`,
# `${t/<text>*/}`, `${t/[<set>]*/}` or `${t##*[![:space:]]}`: bash tries those at every position
# before the cut that could start a match, each against the whole rest of the text, and the time
# grows with the square of its length (20 KB took 11 s, 20,000 trailing blanks 6 s, 4,000 piped
# calls 95 s; measured 2026-10-03, fixing #302).
TRAIL_BLANKS_RE='[[:space:]]*$'
# gql_strip <text> <1 if its lines are as written>: the text without its string values ("…", with
# \-escapes, and """…""", with \""" inside) and, when its lines are as written, its comments (from a
# `#` to the end of the line), as GraphQL's lexer reads them, in GQL_STRIPPED. A text with its lines
# joined that holds a `#` is left whole: a `"` in a comment could not be told from one that opens a
# string. So is one longer than GQL_TEXT_MAX (whole is the stricter reading; real GraphQL values:
# 1,066 bytes at most over the 31 days to 2026-10-03). Read through a window of GQL_STRIP_CHUNK bytes
# and a piece at a time, from one `"`, `\`, `#` or end of line to the next: every `${s:k:1}` or cut of
# the text copies all of it, and reading it a character at a time took 1.5 s on 18 KB (#302).
GQL_STRIPPED=""
GQL_TEXT_MAX=65536
GQL_STRIP_CHUNK=512
GQL_CODE_RE='^[^"#]*'
GQL_COMMENT_RE=$'^[^\n\r]*'
GQL_STRING_RE='^[^\"]*'
GQL_BLOCK_END_RE='"""(.*)$'
gql_strip() {
  local LC_ALL=C s="$1" out="" b="" pre st=code ci=0 nc k
  local -a cs=()
  GQL_STRIPPED="$s"
  [ "$2" -eq 1 ] || [[ "$s" != *'#'* ]] || return 0
  [ "${#s}" -le "$GQL_TEXT_MAX" ] || return 0
  for ((k = 0; k < ${#s}; k += GQL_STRIP_CHUNK)); do cs+=("${s:k:GQL_STRIP_CHUNK}"); done
  nc=${#cs[@]}
  while :; do
    # At least 8 bytes in the window while there are more: enough to see `"""` and `\"""` whole.
    while [ "${#b}" -lt 8 ] && [ "$ci" -lt "$nc" ]; do
      b+="${cs[ci]}"
      ci=$((ci + 1))
    done
    [ -n "$b" ] || break
    [ $((ci & 15)) -ne 0 ] || check_deadline
    case "$st" in
      code)
        case "$b" in
          '#'*)
            out+=' '
            b="${b:1}"
            st=comment
            ;;
          '"""'*)
            out+=' "" '
            b="${b:3}"
            st=block
            ;;
          '"'*)
            out+=' "" '
            b="${b:1}"
            st=string
            ;;
          *)
            [[ "$b" =~ $GQL_CODE_RE ]]
            out+="${BASH_REMATCH[0]}"
            b="${b:${#BASH_REMATCH[0]}}"
            ;;
        esac
        ;;
      comment)
        # To the end of its line; the newline itself is read as code.
        [[ "$b" =~ $GQL_COMMENT_RE ]]
        b="${b:${#BASH_REMATCH[0]}}"
        [ -z "$b" ] || st=code
        ;;
      string)
        # To the closing ", past each \-escape.
        case "$b" in
          '\'*) b="${b:2}" ;;
          '"'*)
            b="${b:1}"
            st=code
            ;;
          *)
            [[ "$b" =~ $GQL_STRING_RE ]]
            b="${b:${#BASH_REMATCH[0]}}"
            ;;
        esac
        ;;
      block)
        # To the closing """, past each \""" inside. Without one in the window, its last 3 bytes stay
        # for the next: a `"""` (or the `\` in front of one) may start there.
        if [[ "$b" =~ $GQL_BLOCK_END_RE ]]; then
          pre="${b:0:${#b}-${#BASH_REMATCH[0]}}"
          b="${BASH_REMATCH[1]}"
          [[ "$pre" == *'\' ]] || st=code
        elif [ "$ci" -lt "$nc" ]; then
          b="${b:${#b}-3}"
          b+="${cs[ci]}"
          ci=$((ci + 1))
        else
          b=""
        fi
        ;;
    esac
  done
  GQL_STRIPPED="$out"
}

# The command as the harness sent it, heredoc bodies included, in RAW_COMMAND (read once).
RAW_COMMAND=""
RAW_COMMAND_READ=0
raw_command() {
  [ "$RAW_COMMAND_READ" -eq 1 ] && return 0
  RAW_COMMAND_READ=1
  RAW_COMMAND="$(printf '%s' "${INPUT-}" | node -e '
let d;
try { d = JSON.parse(require("fs").readFileSync(0, "utf8")); } catch (e) { process.exit(0); }
const c = d && d.tool_input ? d.tool_input.command : undefined;
if (typeof c === "string") process.stdout.write(c);
' 2>/dev/null || true)"
  return 0
}

# Assigning one of the two names, in any of the shell's spellings: NAME=…, NAME+=…, NAME[i]=…
CI_IDENTITY_ASSIGN_RE='^(GITHUB_ACTIONS|MWG_WRITE_TOKEN_KIND)(\[[^]]*\])?\+?='
CI_IDENTITY_NAME_RE='^(GITHUB_ACTIONS|MWG_WRITE_TOKEN_KIND)$'
CI_IDENTITY_DEFAULT_RE='\$\{(GITHUB_ACTIONS|MWG_WRITE_TOKEN_KIND):?='

# unquoted <word>: the word with the shell's quotes and backslashes taken out, in UNQUOTED. The
# builtins and env see `"GITHUB_ACTIONS"=true` or `GITHUB_ACT''IONS=true` as the assignment itself.
# The quotes and backslashes come out as bare_text takes them (in time linear in the word's length:
# `${1//[\'\"\\]/}` took the square of it in a UTF-8 locale and in the bash 3.2 of macOS; #302),
# the `$'` byte by byte (LC_ALL=C), which gives the same text.
UNQUOTED=""
unquoted() {
  local LC_ALL=C
  UNQUOTED="${1//\$\'/\'}"
  bare_text "$UNQUOTED"
  UNQUOTED="$BARE_TEXT"
  return 0
}

# shell_words <word> [<word as written>]: the words the shell makes of it, quotes taken out and braces
# expanded, in SHELL_WORDS (`{GITHUB_ACTIONS,X}=true` is two assignments to export and env).
SHELL_WORDS=()
shell_words() {
  local name bare="${2:-$1}"
  unquoted "$1"
  brace_words "$UNQUOTED"
  SHELL_WORDS=("${BRACE_OUT[@]}")
  # Past what brace_words reads, the word may be either name, and its assignment (#306); but only a
  # brace outside quotes expands (`sed 's/{1..12}/x/'` is one word, as written).
  # One linear pass, left to right; an escaped quote opens nothing.
  [ "$BRACE_OVER" -eq 1 ] && bare="$(printf '%s\n' "$bare" | sed -E "s/\\\\.|'[^']*'|\"([^\"\\\\]|\\\\.)*\"//g")"
  if [ "$BRACE_OVER" -eq 1 ] && [[ "$bare" == *'{'* ]]; then
    for name in GITHUB_ACTIONS MWG_WRITE_TOKEN_KIND; do
      could_spell "$UNQUOTED" "$name" && SHELL_WORDS+=("$name" "$name=")
    done
  fi
  return 0
}

deny_ci_identity() {
  deny "the command sets ${1} in the session: it is what tells the merge step of merge-when-green (pr-merge.sh merge) that it runs as that GitHub Actions job, holding the merge App's token, and a session never stands in for that job" \
    "leave ${1} to the GitHub Actions runner; a test sets it inside its own script (the merge-when-green suites do), and env -u ${1} clears it for one command"
}

# The words in front of the command word (assignments, wrappers and theirs) and the command word
# itself, which is where a bare `NAME=…` or `NAME+=…` statement stands; and the `${NAME:=…}`
# expansion, which assigns as it expands. Reads tok and PFX_END (see check_segment).
check_ci_identity_prefix() {
  local k w last=$PFX_END
  [ "$last" -lt "${#tok[@]}" ] || last=$((${#tok[@]} - 1))
  for ((k = 0; k <= last; k++)); do
    shell_words "${tok[k]}" "${raw[k]-}"
    for w in "${SHELL_WORDS[@]}"; do
      if [[ "$w" =~ $CI_IDENTITY_ASSIGN_RE ]]; then deny_ci_identity "${BASH_REMATCH[1]}"; fi
    done
  done
  if [[ "$seg" =~ $CI_IDENTITY_DEFAULT_RE ]]; then deny_ci_identity "${BASH_REMATCH[1]}"; fi
  return 0
}

# The builtins that set or export a variable they name: export, declare/typeset (with -x, a bare
# name is exported), readonly, local and let (with a value), printf -v and read.
check_ci_identity_builtin() {
  local k n=${#tok[@]} a w opts=""
  case "$cmd0" in
    printf)
      for ((k = 1; k < n; k++)); do
        a="${tok[k]}"
        case "$a" in
          -v) a="${tok[k + 1]-}" ;;
          -v?*) a="${a#-v}" ;;
          *) continue ;;
        esac
        shell_words "$a" "${raw[k]-}${raw[k + 1]-}"
        for w in "${SHELL_WORDS[@]}"; do
          w="${w%%\[*}"
          if [[ "$w" =~ $CI_IDENTITY_NAME_RE ]]; then deny_ci_identity "$w"; fi
        done
      done
      return 0
      ;;
    read)
      for ((k = 1; k < n; k++)); do
        a="${tok[k]}"
        case "$a" in
          # A redirection's target, a here-string included, is data, not a name.
          '<'* | '>'* | [0-9]'<'* | [0-9]'>'* | '&>'*) break ;;
          # -d, -i, -n, -N, -p, -t and -u take the next word as their value (-a names an array).
          -*[dinNptu]) k=$((k + 1)) ;;
          *)
            shell_words "$a" "${raw[k]-}"
            for w in "${SHELL_WORDS[@]}"; do
              if [[ "$w" =~ $CI_IDENTITY_NAME_RE ]]; then deny_ci_identity "$w"; fi
            done
            ;;
        esac
      done
      return 0
      ;;
  esac
  for ((k = 1; k < n; k++)); do
    a="${tok[k]}"
    case "$a" in
      -*)
        opts+="${a#-}"
        continue
        ;;
      +*) continue ;;
    esac
    shell_words "$a" "${raw[k]-}"
    for a in "${SHELL_WORDS[@]}"; do
      if [[ "$a" =~ $CI_IDENTITY_ASSIGN_RE ]]; then deny_ci_identity "${BASH_REMATCH[1]}"; fi
      # A nameref (declare/typeset/local -n) to one of them sets it through another name.
      if [[ "$opts" == *n* && "$cmd0" != export && "${a#*=}" =~ $CI_IDENTITY_NAME_RE ]]; then
        deny_ci_identity "${a#*=}"
      fi
      if [[ "$a" =~ $CI_IDENTITY_NAME_RE ]]; then
        case "$cmd0" in
          export) [[ "$opts" == *[np]* ]] || deny_ci_identity "$a" ;;
          declare | typeset) [[ "$opts" == *x* && "$opts" != *p* ]] && deny_ci_identity "$a" ;;
        esac
      fi
    done
  done
  return 0
}

# mwg_py_cluster <-cluster>: the first of python's value-taking short options (c, m, W, X) in a
# cluster, in PY_LETTER (empty: none), and what follows it in the same word, in PY_REST.
PY_LETTER=""
PY_REST=""
mwg_py_cluster() {
  local w="${1#-}" j c
  PY_LETTER="" PY_REST=""
  for ((j = 0; j < ${#w}; j++)); do
    c="${w:j:1}"
    case "$c" in
      c | m | W | X)
        PY_LETTER="$c"
        PY_REST="${w:j+1}"
        return 0
        ;;
    esac
  done
  return 0
}

# The step a session never runs: `pr-merge.sh merge`, called directly, through a shell or python
# (`bash -euo pipefail pr-merge.sh merge`, `python3 pr_merge.py merge`, `python3 -m pr_merge merge`)
# or sourced. The subcommand is the first argument after the script (or the module); one the shell
# fills in (a variable, a substitution, what xargs reads) may be `merge`, so it is denied too.
# `decide`, `sweep`, `--help` and the rest pass. A script the shell or python reads from stdin
# (`bash -s`, `python3 -`), from a descriptor (`/dev/stdin`, `/dev/fd/N`) or from a word the shell
# fills in is this one when the command names it (`cat pr-merge.sh | bash -s merge`), unless what
# it reads is a heredoc or a here-string.
check_mwg_merge() {
  local k=1 n=${#tok[@]} a s="" si="" sub rawsub module=0 elsewhere=0
  case "$cmd0" in
    pr-merge.sh | pr_merge.py) s=0 ;;
    source | .) s=1 ;;
    bash | sh | dash | zsh | ksh | ash | mksh)
      while [ "$k" -lt "$n" ]; do
        a="${tok[k]}"
        # -s: the script comes from stdin, and every word after the options is its argument.
        [[ "$a" == -* && "$a" != --* && "$a" == *s* ]] && elsewhere=1
        case "$a" in
          --)
            k=$((k + 1))
            break
            ;;
          --rcfile | --init-file) k=$((k + 2)) ;;
          --*) k=$((k + 1)) ;;
          # -c runs a command string, which the extractor reads as a command of its own.
          -*c*) return 0 ;;
          # A cluster that ends in o/O takes the next word as its option name (`-euo pipefail`).
          [-+]*[oO]) k=$((k + 2)) ;;
          -* | +*) k=$((k + 1)) ;;
          *) break ;;
        esac
      done
      s=$k
      if [ "$elsewhere" -eq 1 ]; then si=$k; else si=$((k + 1)); fi
      ;;
    python | python[0-9]*)
      while [ "$k" -lt "$n" ]; do
        a="${tok[k]}"
        case "$a" in
          --)
            k=$((k + 1))
            break
            ;;
          # `python3 - …`: the script comes from stdin, and its arguments follow.
          -)
            elsewhere=1
            k=$((k + 1))
            break
            ;;
          --check-hash-based-pycs) k=$((k + 2)) ;;
          --*) k=$((k + 1)) ;;
          -?*)
            # A cluster of short options: c, m, W and X take the rest of the word, or the next
            # word when nothing is left (`-c '…'`, `-um pr_merge`, `-Werror`, `-X dev`).
            mwg_py_cluster "$a"
            case "$PY_LETTER" in
              # -c runs a command string, not a script file.
              c) return 0 ;;
              # -m runs a module as the script: pr_merge (any package path) is this one.
              m)
                if [ -n "$PY_REST" ]; then a="$PY_REST"; else k=$((k + 1)); a="${tok[k]-}"; fi
                a="${a//[\"\'\\]/}"
                [ "${a##*.}" = pr_merge ] || return 0
                s=$k
                module=1
                break
                ;;
              W | X) if [ -n "$PY_REST" ]; then k=$((k + 1)); else k=$((k + 2)); fi ;;
              *) k=$((k + 1)) ;;
            esac
            ;;
          *) break ;;
        esac
      done
      [ "$module" -eq 1 ] || s=$k
      if [ "$elsewhere" -eq 1 ]; then si=$k; else si=$((s + 1)); fi
      ;;
    *) return 0 ;;
  esac
  [ -n "$si" ] || si=$((s + 1))
  if [ "$elsewhere" -eq 0 ]; then
    [ "$s" -lt "$n" ] || return 0
    unquoted "${tok[s]}"
    if [ "$module" -eq 1 ]; then BASE_NAME="pr_merge.py"; else base_name "$UNQUOTED"; fi
    case "$BASE_NAME" in
      pr-merge.sh | pr_merge.py) ;;
      *)
        # A script read from a descriptor, or one the shell fills in (`bash <(cat …)`, `"$S"`).
        case "$UNQUOTED" in
          /dev/stdin | /dev/fd/* | /proc/*/fd/* | *'$'* | *'`'*) elsewhere=1 ;;
        esac
        ;;
    esac
  fi
  if [ "$elsewhere" -eq 1 ]; then
    # Fed a heredoc or a here-string, the script is that text, not this one.
    [[ "$seg" =~ (^|[^<])\<\<([^<]|$) || "$seg" == *'<<<'* ]] && return 0
    case "$SEGMENTS" in
      *pr-merge.sh* | *pr_merge*) BASE_NAME="pr-merge.sh" ;;
      *) return 0 ;;
    esac
  fi
  case "$BASE_NAME" in
    pr-merge.sh | pr_merge.py) ;;
    *) return 0 ;;
  esac
  rawsub="${raw[si]-}"
  sub="${tok[si]-}"
  sub="${sub//[\"\'\\]/}"
  # Brace expansion makes several words of one (`{merge,x}`): the first is the subcommand.
  brace_words "$sub"
  sub="${BRACE_OUT[0]}"
  # Past what brace_words reads, the subcommand may be any: as if the shell filled it in (#306).
  [ "$BRACE_OVER" -eq 1 ] && sub='$'
  if [ -z "$rawsub" ]; then
    # Without a replace string, xargs appends what it reads: the subcommand comes from stdin.
    [ "$SEG_XARGS" -eq 1 ] && [ "$SEG_APPEND" -eq 1 ] && sub='$'
  elif [[ "$rawsub" == *'$'* || "$rawsub" == *'`'* ]] || { [ -n "$SEG_REPL" ] && [[ "$rawsub" == *"$SEG_REPL"* ]]; }; then
    sub='$'
  fi
  case "$sub" in
    merge)
      deny "${BASE_NAME} merge is the merge step of the merge-when-green job: it merges with the merge App's token, from GitHub Actions only, after the job's own gates, and a session never runs it" \
        "in a session read its decision with ${BASE_NAME} decide --repo <owner>/<name> --pr <n> (read-only), and merge with gh pr merge (no --admin) where the repository's policy lets an agent merge; to exercise the merge path, run the suite (merge-when-green/merge-when-green.test.sh)"
      ;;
    '$')
      deny "${BASE_NAME} is given its subcommand by something the shell fills in later, which the guard cannot read, and the merge subcommand is the merge-when-green job's alone" \
        "write the subcommand in the command: ${BASE_NAME} decide --repo <owner>/<name> --pr <n>"
      ;;
  esac
  return 0
}

# The files a word names are the ones the SHELL opens. Quotes do not change them; outside quotes, a
# backslash only escapes the next character; brace expansion turns one word into several; and an
# unquoted glob reaches every file it matches. So a word is judged as the shell reads it (quote
# characters removed, and its backslashes too when no part of it is quoted), once per word its
# braces make (brace_words), and an unquoted glob that matches a real environment file (env_glob)
# counts as one. A quoted pattern (`grep '\.env'`, `grep -E 'saved .* ok'`) is not a glob: the
# shell passes it as written.
check_env_dump() {
  local k a w x quoted rq=0 sq="'"
  for ((k = 1; k < ${#tok[@]}; k++)); do
    a="${tok[k]}"
    # Only a name that starts with `.` (or a word with braces, quotes or backslashes, which the
    # shell may turn into one) can be an environment file: the rest is skipped cheaply.
    case "$a" in .* | */.* | *[\{\"\'\\]*) ;; *) continue ;; esac
    quoted=0
    case "${raw[k]:-$a}" in *[\"\']*) quoted=1 ;; esac
    # A whitespace token may sit inside a quoted string that an earlier token opened.
    if [ "$quoted" -eq 0 ] && [[ "$a" == *[\\*?[]* ]]; then
      [ "$rq" -eq 1 ] || raw_quoting
      rq=1
      quoted="${RAWQ[k]:-0}"
    fi
    # $'…' and $"…" are quotes too. The quote put back is a variable: the bash 3.2 of macOS keeps the
    # backslash of a `\'` written there, and `cat $'.env'` read as `\.env` (bash 5 denies it).
    w="${a//\$\'/$sq}"
    w="${w//\$\"/\"}"
    if [ "$quoted" -eq 1 ]; then w="${w//[\"\']/}"; else w="${w//\\/}"; fi
    brace_words "$w" .env
    if [ "$BRACE_OVER" -eq 1 ] && [[ "$w" == *env* ]]; then
      deny_env_dump "$a"
    fi
    for x in "${BRACE_OUT[@]}"; do
      is_env_file "$x" && deny_env_dump "$a"
      [ "$quoted" -eq 0 ] && env_glob "$x" && deny_env_dump "$a"
    done
  done
  return 0
}

# RAWQ[k] is 1 when any part of the whitespace token raw[k] (from the command word on) is quoted: it
# holds a quote character, or it starts inside a quote an earlier token opened. One pass over the
# characters of the segment: linear, like egress_words.
RAWQ=()
raw_quoting() {
  local LC_ALL=C k j t c q="" start n
  RAWQ=()
  for ((k = 0; k < ${#raw[@]}; k++)); do
    t="${raw[k]}"
    start="$q"
    n=${#t}
    for ((j = 0; j < n; j++)); do
      c="${t:j:1}"
      if [ "$q" = "'" ]; then
        [ "$c" = "'" ] && q=""
        continue
      fi
      if [ "$c" = '\' ]; then
        j=$((j + 1))
        continue
      fi
      if [ "$q" = '"' ]; then
        [ "$c" = '"' ] && q=""
        continue
      fi
      case "$c" in "'" | '"') q="$c" ;; esac
    done
    if [ -n "$start" ] || [[ "$t" == *[\"\']* ]]; then RAWQ+=(1); else RAWQ+=(0); fi
  done
  return 0
}

deny_env_dump() {
  deny "dumping the contents of '${1}' would expose credentials in the transcript" \
    "read its template instead (.env.example, or .env.<name>.example / .sample / .template) or ask the user for the specific value"
}

# A glob whose matches include a real environment file: its name starts with a literal `.` (the
# shell never matches a leading dot otherwise) and it matches `.env` or a `.env.<name>`.
env_glob() {
  local base s
  base_name "$1"
  base="$BASE_NAME"
  case "$base" in .*) ;; *) return 1 ;; esac
  case "$base" in *[*?[]*) ;; *) return 1 ;; esac
  for s in .env .env.local .env.dev .env.development .env.prod .env.production .env.staging .env.test; do
    # shellcheck disable=SC2053 # the right side is a pattern on purpose
    [[ "$s" == $base ]] && return 0
  done
  return 1
}

# brace_words <word> [<needle>]: the words the shell's brace expansion makes of <word> (comma lists,
# nested ones included, and sequences: see brace_seq) in BRACE_OUT. A `{` right after `$`
# opens a parameter expansion, not a list. With a needle, only a word that can expand into one
# containing it is expanded: a comma list keeps the order of what it copies, so the needle's
# characters are in <word> in that order (a sequence makes characters of its own: a word holding
# `..` is always expanded). Past BRACE_MAX words the expansion stops and BRACE_OVER is 1; a word
# longer than BRACE_MAX_LEN is not expanded, and BRACE_OVER is 1 too: it may expand into any word,
# and every caller treats it as possibly the name it looks for (found 2026-10-03: such a word slipped
# past the callers that read only BRACE_OUT, #306). A word that holds no list or sequence, or not the
# needle's characters in order, is never over.
BRACE_OUT=()
BRACE_OVER=0
BRACE_MAX=64
BRACE_MAX_LEN=2048
brace_words() {
  local w="$1" needle="${2:-}" r k
  local -a todo=()
  BRACE_OUT=("$w")
  BRACE_OVER=0
  [[ "$w" == *'{'* && ("$w" == *,* || "$w" == *..*) ]] || return 0
  r="$w"
  [[ "$w" == *..* ]] && needle=""
  for ((k = 0; k < ${#needle}; k++)); do
    [[ "$r" == *"${needle:k:1}"* ]] || return 0
    r="${r#*"${needle:k:1}"}"
  done
  if [ "${#w}" -gt "$BRACE_MAX_LEN" ]; then
    BRACE_OVER=1
    return 0
  fi
  BRACE_OUT=()
  todo=("$w")
  while [ "${#todo[@]}" -gt 0 ]; do
    w="${todo[0]}"
    todo=("${todo[@]:1}")
    if brace_split "$w"; then
      for r in "${BR_ALTS[@]}"; do todo+=("${BR_PRE}${r}${BR_POST}"); done
      if [ $((${#todo[@]} + ${#BRACE_OUT[@]})) -gt "$BRACE_MAX" ]; then
        BRACE_OVER=1
        return 0
      fi
    else
      BRACE_OUT+=("$w")
    fi
  done
  return 0
}

# could_spell <word> <name>: <word> holds the characters of <name> in order, so that its braces could
# expand into a word containing it (a comma list keeps the order of what it copies). For a word
# brace_words leaves over (BRACE_OVER): only the names it could spell count as possibly there. A
# sequence (`{a..e}`, `{1..40}`) makes characters of its own: it is read as every character of its
# range, in order (a superset of what any one word gets), and one the guard cannot read could spell
# anything.
could_spell() {
  local r="$1" k c x y lo hi chars pre post
  while [[ "$r" == *..* ]]; do
    if [[ "$r" =~ ^(.*)\{([A-Za-z]|-?[0-9]{1,6})\.\.([A-Za-z]|-?[0-9]{1,6})(\.\.-?[0-9]{1,6})?\}(.*)$ ]]; then
      pre="${BASH_REMATCH[1]}" x="${BASH_REMATCH[2]}" y="${BASH_REMATCH[3]}" post="${BASH_REMATCH[5]}" chars=""
      if [[ "$x$y" =~ ^-?[0-9]+-?[0-9]+$ ]]; then
        lo=$((x < y ? x : y)) hi=$((x < y ? y : x))
        [ $((hi - lo)) -le 1000 ] || return 0
        chars="$(seq "$lo" "$hi" | tr -d '\n')"
      elif [[ "$x$y" =~ ^[A-Za-z][A-Za-z]$ ]]; then
        lo="$(printf '%d' "'$x")" hi="$(printf '%d' "'$y")"
        [ "$lo" -le "$hi" ] || { k="$lo"; lo="$hi"; hi="$k"; }
        for ((k = lo; k <= hi; k++)); do chars+="$(printf '%b' "\\$(printf '%03o' "$k")")"; done
      else
        return 0
      fi
      r="${pre}${chars}${post}"
      [ "${#r}" -le 65536 ] || return 0
    else
      return 0
    fi
  done
  for ((k = 0; k < ${#2}; k++)); do
    c="${2:k:1}"
    [[ "$r" == *"$c"* ]] || return 1
    r="${r#*"$c"}"
  done
  return 0
}

# brace_split <word>: the first brace of <word> that brace expansion splits, as BR_PRE, BR_ALTS
# (its comma-separated alternatives, or the words of its sequence) and BR_POST. Exit 1: there is none.
BR_PRE=""
BR_POST=""
BR_ALTS=()
brace_split() {
  # LC_ALL=C first, on its own: the words of one `local` are expanded before any is set, and n
  # counted in characters while the loop reads bytes left the last braces of a word holding
  # multibyte characters unread (found 2026-10-03, fixing #302: `--remove-label` with 40 `é` and
  # then `,no-autom{e,x}rge` passed).
  local LC_ALL=C
  local w="$1" n=${#1} s j c depth from cm
  local -a commas=()
  BR_ALTS=()
  for ((s = 0; s < n; s++)); do
    [ "${w:s:1}" = "{" ] || continue
    [ "$s" -gt 0 ] && [ "${w:s-1:1}" = '$' ] && continue
    depth=0
    commas=()
    for ((j = s; j < n; j++)); do
      c="${w:j:1}"
      case "$c" in
        '{') depth=$((depth + 1)) ;;
        '}')
          depth=$((depth - 1))
          [ "$depth" -eq 0 ] && break
          ;;
        ,) [ "$depth" -eq 1 ] && commas+=("$j") ;;
      esac
    done
    [ "$j" -lt "$n" ] || continue
    if [ "${#commas[@]}" -eq 0 ]; then
      brace_seq "${w:s+1:j-s-1}" || continue
      BR_PRE="${w:0:s}"
      BR_POST="${w:j+1}"
      return 0
    fi
    BR_PRE="${w:0:s}"
    BR_POST="${w:j+1}"
    from=$((s + 1))
    for cm in "${commas[@]}"; do
      BR_ALTS+=("${w:from:cm-from}")
      from=$((cm + 1))
    done
    BR_ALTS+=("${w:from:j-from}")
    return 0
  done
  return 1
}

# brace_seq <what is between the braces>: the words of a sequence expression {x..y} or
# {x..y..incr}, in BR_ALTS, as bash makes them (`.e{n..n}v` is .env, `d{e..e}velop` is develop):
# x and y both integers, zero-padded to the wider of the two when either is written with a leading
# zero, or both single letters (every character between them); every incr-th one, whose sign does
# not count and 0 stands for 1. Exit 1: not a sequence, and the shell leaves it as written. One word
# past BRACE_MAX is enough for brace_words to stop, so no more are made: `{1..99999999}` costs nothing.
brace_seq() {
  local t="$1" x y inc a b sx sy width=0 count k cur v LC_ALL=C
  BR_ALTS=()
  [[ "$t" =~ ^([^.]+)\.\.([^.]+)(\.\.([^.]+))?$ ]] || return 1
  x="${BASH_REMATCH[1]}" y="${BASH_REMATCH[2]}" inc="${BASH_REMATCH[4]:-1}"
  [[ "$inc" =~ ^[-+]?[0-9]{1,18}$ ]] || return 1
  inc="${inc#[-+]}"
  inc=$((10#$inc))
  [ "$inc" -gt 0 ] || inc=1
  if [[ "$x" =~ ^[-+]?[0-9]{1,18}$ && "$y" =~ ^[-+]?[0-9]{1,18}$ ]]; then
    sx="${x#[-+]}" sy="${y#[-+]}"
    a=$((10#$sx)) b=$((10#$sy))
    [ "${x:0:1}" = - ] && a=$((-a))
    [ "${y:0:1}" = - ] && b=$((-b))
    if [[ "$sx" == 0?* || "$sy" == 0?* ]]; then
      width=${#x}
      [ "${#y}" -gt "$width" ] && width=${#y}
    fi
  elif [[ "$x" =~ ^[A-Za-z]$ && "$y" =~ ^[A-Za-z]$ ]]; then
    printf -v a '%d' "'$x"
    printf -v b '%d' "'$y"
    width=-1
  else
    return 1
  fi
  if [ "$a" -le "$b" ]; then count=$(((b - a) / inc + 1)); else count=$(((a - b) / inc + 1)); fi
  [ "$count" -le $((BRACE_MAX + 1)) ] || count=$((BRACE_MAX + 1))
  [ "$a" -le "$b" ] || inc=$((-inc))
  cur=$a
  for ((k = 0; k < count; k++)); do
    if [ "$width" -lt 0 ]; then
      printf -v v '%x' "$cur"
      printf -v v "\\x$v"
    else
      printf -v v '%0*d' "$width" "$cur"
    fi
    BR_ALTS+=("$v")
    cur=$((cur + inc))
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

# --- Egress: the destination must be literal --------------------------------
# The allow-list below judges the host WRITTEN in the command. A host that only exists after
# the shell expands something — a variable, a command substitution, a word the shell builds —
# is not written anywhere the guard can read, so the rule is: every word curl/wget would take
# as a destination names its scheme and host literally, and a `$` or backtick in that part is
# denied. The path after a literal host may hold expansions: it cannot change the host.
#
# Which words are destinations: every positional word, plus the value of any option that is
# not listed below as a NON-destination value (output file, header, data, auth, timeouts…).
# An option this rule does not know is taken as a flag, so its next word is judged as a
# destination — fail-closed. And a tool told to read its URLs from a file is denied outright:
# a destination nobody wrote in the command cannot be judged.

# Shell words of a segment, honouring quotes and backslashes. A `$` or backtick the shell would
# expand is kept; one it would not (inside single quotes, or escaped) becomes \x1f, so "does
# this word hold an expansion" is a plain substring test. An expansion OUTSIDE any quotes — a
# `$`, a backtick, or a brace that expands (an unquoted `,` or `..` before its closing brace) —
# also puts \x1e in the word: the shell may split or multiply it, so what it turns into is not
# one destination the guard can read.
#
# Linear in the length of the segment, and it has to be: a hook that grows quadratically with
# its input turns a long command into a hook timeout. So the scan runs byte-wise (LC_ALL=C: a
# character offset in a multibyte locale costs a walk from the start of the string) over
# fixed-size chunks (an offset into a short chunk costs the same wherever the chunk sits), and
# nothing inside the loop copies the remainder of the string. A run of characters that only go into
# the word as they are is taken in one step: a character at a time, a command word of 6,000 `$()`
# took seconds (found 2026-10-03, third verification round of #299).
EGRESS_WORDS=()
# What ends such a run: outside quotes, inside single quotes, inside double quotes.
EGRESS_RUN_END_U=$'[ \t\'"\\\\$`{,.}]*'
EGRESS_RUN_END_S=$'[\'$`]*'
EGRESS_RUN_END_D=$'["\\\\]*'
egress_words() {
  local LC_ALL=C
  local s="$1" w="" q="" c chunk i j m off n=${#1} inword=0 esc=0 br=0 brsep=0 dot=0 run
  EGRESS_WORDS=()
  for ((off = 0; off < n; off += 4096)); do
    chunk="${s:off:4096}"
    m=${#chunk}
    for ((j = 0; j < m; j++)); do
      if ((!esc)); then
        run="${chunk:j}"
        case "$q" in
          "'") run="${run%%$EGRESS_RUN_END_S}" ;;
          '"') run="${run%%$EGRESS_RUN_END_D}" ;;
          *) run="${run%%$EGRESS_RUN_END_U}" ;;
        esac
        if [ -n "$run" ]; then
          w+="$run"
          j=$((j + ${#run} - 1))
          [ -n "$q" ] || dot=0 inword=1
          continue
        fi
      fi
      c="${chunk:j:1}"
      if ((esc)); then
        # The character after a backslash, outside single quotes.
        esc=0
        if [[ $q == '"' ]]; then
          case "$c" in
            '$' | '`') w+=$'\x1f' ;;
            '"' | '\') w+="$c" ;;
            *) w+='\'"$c" ;;
          esac
        else
          case "$c" in '$' | '`') c=$'\x1f' ;; esac
          w+="$c"
          inword=1
        fi
        continue
      fi
      if [[ $q == "'" ]]; then
        if [[ $c == "'" ]]; then
          q=""
        else
          case "$c" in '$' | '`') c=$'\x1f' ;; esac
          w+="$c"
        fi
        continue
      fi
      if [[ $q == '"' ]]; then
        case "$c" in
          '"') q="" ;;
          '\') esc=1 ;;
          *) w+="$c" ;;
        esac
        continue
      fi
      case "$c" in
        ' ' | $'\t')
          ((inword)) && EGRESS_WORDS+=("$w")
          w="" inword=0 br=0 brsep=0 dot=0
          continue
          ;;
        "'" | '"') q="$c" ;;
        '\') esc=1 ;;
        '$' | '`') w+=$'\x1e'"$c" ;;
        '{') br=$((br + 1)); w+="$c" ;;
        ',') ((br)) && brsep=1; w+="$c" ;;
        '.')
          ((br && dot)) && brsep=1
          w+="$c"
          ;;
        '}')
          if ((br)); then
            ((brsep)) && w+=$'\x1e'
            br=$((br - 1))
          fi
          w+="$c"
          ;;
        *) w+="$c" ;;
      esac
      [[ $c == "." ]] && dot=1 || dot=0
      inword=1
    done
  done
  if [ "$inword" -eq 1 ]; then EGRESS_WORDS+=("$w"); fi
  return 0
}

# Options whose value is NOT a destination, per tool: long names, then short letters. Then the
# options that read URLs from a file, and the short ones whose value IS a destination (a proxy,
# a base URL): theirs is judged whether it is attached or the next word.
EGRESS_CURL_VALUE_LONG=" --output --output-dir --header --proxy-header --data --data-raw --data-binary --data-ascii --data-urlencode --json --form --form-string --user --user-agent --referer --request --write-out --cookie --cookie-jar --upload-file --connect-timeout --max-time --retry --retry-delay --retry-max-time --cacert --capath --cert --cert-type --key --key-type --pass --ciphers --range --time-cond --limit-rate --continue-at --speed-limit --speed-time --max-filesize --max-redirs --dump-header --trace --trace-ascii --stderr --netrc-file --oauth2-bearer --aws-sigv4 --expect100-timeout --keepalive-time --create-file-mode --proxy-user --proto --proto-redir --etag-save --etag-compare --pinnedpubkey --hostpubmd5 --hostpubsha256 --crlfile --delegation --login-options --sasl-authzid --service-name --tls-max --ftp-method --ftp-account --ftp-alternative-to-user --krb --mail-from --mail-rcpt --mail-auth --quote --telnet-option --local-port --interface --dns-interface --dns-ipv4-addr --dns-ipv6-addr --unix-socket --abstract-unix-socket --parallel-max --rate --variable "
EGRESS_CURL_VALUE_SHORT="oHdFuAeXwbcTmErzCYyDUQtP"
EGRESS_CURL_FROM_FILE_LONG=" --config "
EGRESS_CURL_FROM_FILE_SHORT="K"
EGRESS_CURL_DEST_SHORT="x"
EGRESS_WGET_VALUE_LONG=" --output-document --output-file --append-output --directory-prefix --header --user-agent --user --password --http-user --http-password --ftp-user --ftp-password --proxy-user --proxy-password --post-data --post-file --body-data --body-file --method --tries --timeout --connect-timeout --read-timeout --dns-timeout --wait --waitretry --random-wait --referer --load-cookies --save-cookies --limit-rate --quota --level --accept --reject --accept-regex --reject-regex --include-directories --exclude-directories --domains --exclude-domains --certificate --certificate-type --private-key --private-key-type --ca-certificate --ca-directory --crl-file --progress --restrict-file-names --default-page --cut-dirs --max-redirect --local-encoding --remote-encoding --bind-address --dns-servers --secure-protocol --ciphers --pinnedpubkey --report-speed --warc-file --warc-header --warc-max-size --warc-tempdir --warc-dedup --warc-cdx --compression "
EGRESS_WGET_VALUE_SHORT="OoaPUtTwQlARIXD"
EGRESS_WGET_FROM_FILE_LONG=" --input-file --input-metalink --config "
EGRESS_WGET_FROM_FILE_SHORT="i"
EGRESS_WGET_DEST_SHORT="eB"

# What every egress deny says about READING the web. Most of these denies are an agent reading
# a public page or doc, and WebFetch is the tool for that: measured over the 30 days to
# 2026-09-30, of 202 egress denies 85 went on to WebFetch/WebSearch within five tool calls, but
# 24 were followed by ANOTHER curl/wget deny and 23 by a detour through ssh or another HTTP
# client — the same egress by another door. A message that names the right tool saves the
# turns; one that only says "no" teaches the detour.
EGRESS_READ_HINT="to READ a public page, doc or API answer, use the WebFetch tool instead of curl/wget"

deny_egress_nonliteral() {
  local shown="${1//$'\x1e'/}"
  shown="${shown//$'\x1f'/\$}"
  shown="${shown//\$__GUARD_SUBST__/\$(…)}"
  shown="${shown//"$XARGS_PLACEHOLDER"/<from xargs>}"
  deny "curl/wget toward a destination that is not written literally ('${shown}'): network egress is restricted to the allow-list, and it can only judge a host written in the command" \
    "write the URL with its scheme and host literally, quoted, one command per URL (the path may keep variables inside the quotes); ${EGRESS_READ_HINT}; or ask the user to fetch the resource"
}

deny_egress_from_file() {
  deny "$1: a file can name URLs, and the egress allow-list can only judge a host written in the command" \
    "write the URL literally in the command (headers can come from a file or stdin with -H @file / -H @-); ${EGRESS_READ_HINT}; or ask the user to fetch the resource"
}

# Judge one destination word: no unquoted expansion anywhere, and none in its scheme and host.
egress_judge_word() {
  local w="$1" head
  case "$w" in *$'\x1e'*) deny_egress_nonliteral "$w" ;; esac
  if [[ "$w" =~ ^[A-Za-z][A-Za-z0-9+.-]*:// ]]; then
    head="${w#*://}"
    [ -z "$head" ] && deny_egress_nonliteral "$w" # nothing after the scheme: the host was cut away
    head="${head%%[/?#]*}"
  else
    head="${w%%/*}"
  fi
  case "$head" in
    *'$'* | *'`'*) deny_egress_nonliteral "$w" ;;
  esac
  return 0
}

check_egress_literal() {
  local tool="$1" seg="$2" w n i=0 k ch name val
  local value_long value_short file_long file_short dest_short skip_next=0 opts_done=0
  case "$tool" in
    curl)
      value_long="$EGRESS_CURL_VALUE_LONG" value_short="$EGRESS_CURL_VALUE_SHORT"
      file_long="$EGRESS_CURL_FROM_FILE_LONG" file_short="$EGRESS_CURL_FROM_FILE_SHORT"
      dest_short="$EGRESS_CURL_DEST_SHORT"
      ;;
    *)
      value_long="$EGRESS_WGET_VALUE_LONG" value_short="$EGRESS_WGET_VALUE_SHORT"
      file_long="$EGRESS_WGET_FROM_FILE_LONG" file_short="$EGRESS_WGET_FROM_FILE_SHORT"
      dest_short="$EGRESS_WGET_DEST_SHORT"
      ;;
  esac
  egress_words "$seg"
  n=${#EGRESS_WORDS[@]}
  # Everything up to the command word itself (assignments, wrappers, keywords) is not its args.
  while [ "$i" -lt "$n" ]; do
    w="${EGRESS_WORDS[i]}"
    i=$((i + 1))
    base_name "$w"
    [ "$BASE_NAME" = "$tool" ] && break
  done
  # Under xargs, what it reads from stdin becomes part of the command: in place of its replace
  # string, or appended at the end (one more destination word, unknown).
  if [ "$SEG_XARGS" -eq 1 ] && [ "$SEG_APPEND" -eq 1 ]; then EGRESS_WORDS+=("$XARGS_PLACEHOLDER"); fi
  n=${#EGRESS_WORDS[@]}
  for (( ; i < n; i++)); do
    w="${EGRESS_WORDS[i]}"
    [ -n "$SEG_REPL" ] && w="${w//"$SEG_REPL"/\$}"
    if [ "$skip_next" -eq 1 ]; then
      skip_next=0
      continue
    fi
    if [ "$opts_done" -eq 0 ]; then
      case "$w" in
        --)
          opts_done=1
          continue
          ;;
        --*=*)
          name="${w%%=*}" val="${w#*=}"
          [[ "$file_long" == *" $name "* ]] && deny_egress_from_file "${tool} ${name}"
          [[ "$value_long" == *" $name "* ]] || egress_judge_word "$val"
          continue
          ;;
        --*)
          [[ "$file_long" == *" $w "* ]] && deny_egress_from_file "${tool} ${w}"
          [[ "$value_long" == *" $w "* ]] && skip_next=1
          continue
          ;;
        -?*)
          # A cluster of short options: the first one that takes a value ends it, and that
          # value is the rest of the word or, when nothing is left, the next word.
          for ((k = 1; k < ${#w}; k++)); do
            ch="${w:k:1}"
            [[ "$file_short" == *"$ch"* ]] && deny_egress_from_file "${tool} -${ch}"
            if [[ "$dest_short" == *"$ch"* ]]; then
              [ -n "${w:k+1}" ] && egress_judge_word "${w:k+1}"
              break
            fi
            if [[ "$value_short" == *"$ch"* ]]; then
              [ -z "${w:k+1}" ] && skip_next=1
              break
            fi
          done
          continue
          ;;
      esac
    fi
    egress_judge_word "$w"
  done
  return 0
}

# Egress restricted to the policy allow-list (default: localhost). Universal.
check_egress() {
  local a url host allowed h
  check_egress_literal "$cmd0" "$seg"
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
        deny "curl/wget toward '${host}': network egress is restricted to the allow-list (${EGRESS_ALLOW[*]})" \
          "${EGRESS_READ_HINT}; a local service is reachable on the allowed hosts; if this repository needs a host routinely, ask the user to add it to egress_allow in its guard.policy.json (the owner's decision: never edit the policy to get past this deny); to download or install anything else, ask the user. Sending it through ssh, python or another client is the same egress, not a way around this rule"
      fi
    fi
  done
  return 0
}

# --- Segment analysis -------------------------------------------------------

# Does a whitespace token end inside a word the shell has not finished? It can: `X="a b"` arrives
# as `X="a` and `b"`, and `X=a\ b` as `X=a\` and `b` (the blank was escaped).
# quote_carry <quote open before> <token>: the quote still open after <token>, in QC (empty: none;
# `\` stands for a trailing backslash, which escaped the blank that ended the token). Read one
# token at a time, carrying the state, so a word spread over many tokens is read in one pass.
QC=""
quote_carry() {
  local q="$1" s="$2" c k m off chunk rest pre esc=0 n LC_ALL=C
  [ "$q" = '\' ] && q=""
  n=${#s}
  # Linear, like egress_words: over fixed-size chunks, and from one quote or backslash to the next.
  # A character at a time over the whole token, its offset into it cost a walk of the token each, and
  # a command word of 6,000 `$()` (96 KB as the extractor sends it) took minutes (found 2026-10-03,
  # third verification round of #299).
  for ((off = 0; off < n; off += 4096)); do
    chunk="${s:off:4096}"
    m=${#chunk}
    k=0
    if [ "$esc" -eq 1 ]; then
      esc=0
      k=1
    fi
    while [ "$k" -lt "$m" ]; do
      rest="${chunk:k}"
      if [ "$q" = "'" ]; then
        pre="${rest%%\'*}"
      else
        pre="${rest%%[\'\"\\]*}"
      fi
      k=$((k + ${#pre}))
      [ "$k" -lt "$m" ] || break
      c="${chunk:k:1}"
      k=$((k + 1))
      if [ "$q" = "'" ]; then
        q=""
        continue
      fi
      if [ "$c" = '\' ]; then
        if [ $((off + k)) -ge "$n" ]; then
          [ -n "$q" ] || q='\'
          break
        fi
        if [ "$k" -ge "$m" ]; then esc=1; else k=$((k + 1)); fi
        continue
      fi
      if [ "$q" = '"' ]; then
        [ "$c" = '"' ] && q=""
        continue
      fi
      q="$c"
    done
  done
  QC="$q"
  return 0
}

# --- The command word: what a segment RUNS ------------------------------------
# Every rule judges a segment by its command word, so the words in front of it that are not it
# are skipped: assignments, shell keywords, and WRAPPERS — programs that run the command written
# after their own options (sudo, env, nice, timeout, xargs…). A wrapper is skipped together with
# its options, the values those options take (`sudo -u <user>`, `nice -n <n>`, `stdbuf -o <mode>`)
# and the operands that come before the command (timeout's duration, flock's lock file, chroot's
# new root), so the command word is the program that runs. One skipper serves the two readings of
# a segment (check_segment's whitespace tokens, gh_words' shell words): they must land on the same
# word.
#
# A wrapper not listed here hides the command like an interpreter does (see the header).
#
# xargs also ADDS arguments the command line does not show: read from stdin and appended, or put
# where its replace string is (-I {}). The rules that must read a value — which PR, which host —
# treat those as a value the shell fills in later: PFX_XARGS says xargs is there, PFX_REPL holds
# its replace string (empty: the arguments are appended).

# wrapper_grammar <name>: WG_SHORT = short options whose value is the rest of the word or the next
# word; WG_OPT_ATTACHED = short options whose value can only be attached (xargs -i{} -e -l);
# WG_LONG = long options whose value is the next word when not given with `=`; WG_POS = operands
# before the command. Exit 1: not a wrapper.
WG_SHORT=""
WG_OPT_ATTACHED=""
WG_LONG=" "
WG_POS=0
wrapper_grammar() {
  WG_SHORT="" WG_OPT_ATTACHED="" WG_LONG=" " WG_POS=0
  case "$1" in
    # -S (--split-string) is NOT a value here: its value is the start of the command it runs.
    env) WG_SHORT="uC" WG_LONG=" --unset --chdir " ;;
    sudo)
      WG_SHORT="aCcDghpRrTtUu"
      WG_LONG=" --auth-type --close-from --login-class --chdir --group --host --prompt --chroot --role --type --command-timeout --other-user --user "
      ;;
    doas) WG_SHORT="aCu" ;;
    nice) WG_SHORT="n" WG_LONG=" --adjustment " ;;
    timeout) WG_SHORT="sk" WG_LONG=" --signal --kill-after " WG_POS=1 ;;
    stdbuf) WG_SHORT="ioe" WG_LONG=" --input --output --error " ;;
    ionice) WG_SHORT="cnpPu" WG_LONG=" --class --classdata --pid --pgid --uid " ;;
    time) WG_SHORT="fo" WG_LONG=" --format --output " ;;
    exec) WG_SHORT="a" ;;
    flock) WG_SHORT="wE" WG_LONG=" --wait --timeout --conflict-exit-code " WG_POS=1 ;;
    chroot) WG_LONG=" --userspec --groups " WG_POS=1 ;;
    caffeinate) WG_SHORT="tw" ;;
    runuser)
      WG_SHORT="cgGsuw"
      WG_LONG=" --command --group --supp-group --shell --user --whitelist-environment "
      ;;
    nsenter) WG_SHORT="tSG" WG_OPT_ATTACHED="rwmuinpUCT" WG_LONG=" --target --setuid --setgid " ;;
    unshare)
      WG_SHORT="SGRw" WG_OPT_ATTACHED="muinpUCT"
      WG_LONG=" --setuid --setgid --root --wd --setgroups --propagation --map-user --map-group --map-users --map-groups --monotonic --boottime "
      ;;
    strace) WG_SHORT="abeEIoOpPsSuUX" WG_LONG=" --output --env --user " ;;
    ltrace) WG_SHORT="aADeFlnopsuwx" WG_LONG=" --output --library " ;;
    watch) WG_SHORT="nq" WG_OPT_ATTACHED="d" WG_LONG=" --interval --equexit " ;;
    xargs)
      WG_SHORT="adEILnPs" WG_OPT_ATTACHED="eil"
      WG_LONG=" --arg-file --delimiter --max-args --max-procs --max-chars --process-slot-var "
      ;;
    # GNU parallel runs its command once per input, like xargs (see parallel_inputs for its inputs).
    parallel)
      WG_SHORT="aCdEIjJLnNPsS" WG_OPT_ATTACHED="eil"
      WG_LONG=" --arg-file --arg-file-sep --arg-sep --basefile --bf --basenamereplace --bnr --basenameextensionreplace --bner --block --block-size --colsep --compress-program --decompress-program --delay --delimiter --dirnamereplace --dnr --env --eof --extensionreplace --er --halt --halt-on-error --header --hostgroups --id --jobs --joblog --load --max-args --max-chars --max-line-length-allowed --max-lines --max-procs --max-replace-args --memfree --memsuspend --nice --process-slot-var --profile --recend --recstart --replace --res --results --retries --return --rpl --semaphorename --seqreplace --shebang --slotreplace --sql --sqlandworker --sqlmaster --sqlworker --ssh --sshdelay --sshlogin --sshloginfile --slf --tagstring --termseq --tf --timeout --tmpdir --transferfile --wd --workdir "
      ;;
    # ssh runs the words after its destination (the one operand) on the remote host: unquoted, they
    # are the command the remote shell reads. A quoted one is a command of its own for the extractor.
    ssh) WG_SHORT="BbcDEeFIiJLlmOoPpQRSWw" WG_POS=1 ;;
    # eval joins its words and runs them: unquoted (`eval gh pr merge 5 --admin`) its first word is
    # the command word; a quoted string is also read as a command of its own by the extractor.
    setsid | nohup | command | builtin | busybox | eval) ;;
    *) return 1 ;;
  esac
  return 0
}

# A cluster of short options of the wrapper in WG_*: the first letter that takes a value ends it.
# WC_LETTER is that letter (empty: none), WC_VALUE its attached value, WC_NEXT 1 when the value
# is the next word.
WC_LETTER=""
WC_VALUE=""
WC_NEXT=0
wrapper_cluster() {
  local w="${1#-}" k c
  WC_LETTER="" WC_VALUE="" WC_NEXT=0
  for ((k = 0; k < ${#w}; k++)); do
    c="${w:k:1}"
    if [[ "$WG_SHORT" == *"$c"* ]]; then
      WC_LETTER="$c"
      WC_VALUE="${w:k+1}"
      [ -n "$WC_VALUE" ] || WC_NEXT=1
      WC_VALUE="${WC_VALUE#=}"
      return 0
    fi
    if [[ "$WG_OPT_ATTACHED" == *"$c"* ]]; then
      WC_LETTER="$c"
      WC_VALUE="${w:k+1}"
      return 0
    fi
  done
  return 0
}

# prefix_end: reads PFX_W (the words of a segment) and, when given, PFX_RAW (the same words before
# quote stripping, to join a word whose quoted part spans several of them). Sets PFX_END to the
# index of the command word (>= the number of words: there is none), PFX_XARGS and PFX_REPL, and
# PFX_PARALLEL when GNU parallel is among the wrappers: it adds arguments like xargs (`{}` is its
# replace string when the command holds one; otherwise they are appended). PFX_APPEND: the innermost
# xargs or parallel MAY append what it reads: it set no replace string of its own, or (xargs) it
# also has -L, -l, -n, --max-lines or --max-args, which can cancel the replace string, or an option
# whose name the guard cannot read for quotes or expansions. Judged on the safe side every time:
# a word holding a replace string still counts as filled in, the appended word is still added.
PFX_W=()
PFX_RAW=()
PFX_END=0
PFX_XARGS=0
PFX_REPL=""
PFX_APPEND=0
PFX_PARALLEL=0
# pfx_next <k>: the index right after the word that starts at token k, in PFX_NEXT. With PFX_RAW
# (whitespace tokens), a quoted part with blanks spans several tokens and all of them are that one
# word: an assignment (`X="a b" git push`), an option value (`sudo -u "a b" git push`) or an
# operand (`flock "/tmp/my lock" git push`). Taking the second half for the next word made it the
# command word, which no rule looked at. The quote state is carried token to token: linear.
PFX_NEXT=0
pfx_next() {
  local k="$1" q=""
  if [ "${#PFX_RAW[@]}" -ne "${#PFX_W[@]}" ]; then
    PFX_NEXT=$((k + 1))
    return 0
  fi
  while [ "$k" -lt "${#PFX_RAW[@]}" ]; do
    quote_carry "$q" "${PFX_RAW[k]}"
    q="$QC"
    k=$((k + 1))
    [ -n "$q" ] || break
  done
  PFX_NEXT=$k
  return 0
}
# A redirection may stand anywhere in a simple command, in front of the command word too
# (`2>/dev/null git push …`, `<cmds.txt parallel`): an operator with its target attached is one
# word, and one standing alone takes the next word as its target.
PFX_REDIR_RE='^[0-9]*(<<<|<<-|<<|<>|<&|<|>>|>\||>&|>|&>>|&>)(.*)$'
# An xargs option written with a quote, a backslash or an expansion: the guard cannot read its name.
XARGS_OPAQUE_RE="[\\\\'\"\$\`]"
prefix_end() {
  local n=${#PFX_W[@]} i=0 w name p own_repl=0 may_cancel=0
  PFX_XARGS=0 PFX_REPL="" PFX_APPEND=0 PFX_PARALLEL=0
  while [ "$i" -lt "$n" ]; do
    w="${PFX_W[i]}"
    if [[ "$w" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      pfx_next "$i"
      i=$PFX_NEXT
      continue
    fi
    if [[ "$w" =~ $PFX_REDIR_RE ]]; then
      p="${BASH_REMATCH[2]}"
      pfx_next "$i"
      i=$PFX_NEXT
      if [ -z "$p" ]; then
        pfx_next "$i"
        i=$PFX_NEXT
      fi
      continue
    fi
    case "$w" in
      do | then | else | elif | if | while | until | '{' | '!' | coproc)
        i=$((i + 1))
        continue
        ;;
    esac
    base_name "$w"
    name="$BASE_NAME"
    wrapper_grammar "$name" || break
    own_repl=0 may_cancel=0
    pfx_next "$i"
    i=$PFX_NEXT
    while [ "$i" -lt "$n" ]; do
      w="${PFX_W[i]}"
      if [ "$name" = xargs ]; then
        case "$w" in
          --max-l* | --max-a*) may_cancel=1 ;;
        esac
        [[ "$w" == -* && "${PFX_RAW[i]:-$w}" =~ $XARGS_OPAQUE_RE ]] && may_cancel=1
      fi
      case "$w" in
        --)
          i=$((i + 1))
          break
          ;;
        --*=*)
          [[ "$name" == xargs || "$name" == parallel ]] && [ "${w%%=*}" = --replace ] && PFX_REPL="${w#*=}" && own_repl=1
          # xargs takes any prefix of --replace (`--rep=%`): no other long option of its starts with r.
          [ "$name" = xargs ] && [[ --replace == "${w%%=*}"* ]] && [ "${#w}" -ge 3 ] && PFX_REPL="${w#*=}" && own_repl=1
          pfx_next "$i"
          i=$PFX_NEXT
          ;;
        --?*)
          [ "$name" = xargs ] && [[ --replace == "$w"* ]] && [ "${#w}" -ge 3 ] && PFX_REPL="{}" && own_repl=1
          [ "$name" = parallel ] && [ "$w" = --replace ] && PFX_REPL="${PFX_W[i + 1]:-}" && own_repl=1
          pfx_next "$i"
          i=$PFX_NEXT
          if [[ "$WG_LONG" == *" $w "* ]] || { [ "$name" = xargs ] && xargs_valued_prefix "$w"; }; then
            pfx_next "$i"
            i=$PFX_NEXT
          fi
          ;;
        -)
          # `env -` is `env -i`; for the others a lone `-` is no option.
          [ "$name" = env ] || break
          i=$((i + 1))
          ;;
        -?*)
          wrapper_cluster "$w"
          if [ "$name" = xargs ] || [ "$name" = parallel ]; then
            case "$WC_LETTER" in
              I) if [ "$WC_NEXT" -eq 1 ]; then PFX_REPL="${PFX_W[i + 1]:-}"; else PFX_REPL="$WC_VALUE"; fi; own_repl=1 ;;
              i) if [ -n "$WC_VALUE" ]; then PFX_REPL="$WC_VALUE"; else PFX_REPL='{}'; fi; own_repl=1 ;;
              L | l | n) [ "$name" = xargs ] && may_cancel=1 ;;
            esac
          fi
          pfx_next "$i"
          i=$PFX_NEXT
          if [ "$WC_NEXT" -eq 1 ]; then
            pfx_next "$i"
            i=$PFX_NEXT
          fi
          ;;
        *) break ;;
      esac
    done
    for ((p = 0; p < WG_POS; p++)); do
      pfx_next "$i"
      i=$PFX_NEXT
    done
    # ssh reads its options after the destination too (`ssh host -p 2222 cmd`, measured).
    while [ "$name" = ssh ] && [ "$i" -lt "$n" ]; do
      w="${PFX_W[i]}"
      case "$w" in
        --)
          i=$((i + 1))
          break
          ;;
        -?*)
          wrapper_cluster "$w"
          pfx_next "$i"
          i=$PFX_NEXT
          if [ "$WC_NEXT" -eq 1 ]; then
            pfx_next "$i"
            i=$PFX_NEXT
          fi
          ;;
        *) break ;;
      esac
    done
    [ "$name" = xargs ] && PFX_XARGS=1
    if [ "$name" = parallel ]; then
      PFX_XARGS=1 PFX_PARALLEL=1
      if [ -z "$PFX_REPL" ]; then
        for ((p = i; p < n; p++)); do
          [[ "${PFX_W[p]}" == *'{}'* ]] && PFX_REPL='{}' && own_repl=1 && break
        done
      fi
    fi
    if [ "$name" = xargs ] || [ "$name" = parallel ]; then
      if [ "$own_repl" -eq 0 ] || [ "$may_cancel" -eq 1 ]; then PFX_APPEND=1; else PFX_APPEND=0; fi
    fi
  done
  # Whatever the wrappers said, with no replace string the guard can read xargs appends (2.9.18's
  # rule, kept whole: an empty one, as `-I "'"` leaves it, is no replace string).
  [ -z "$PFX_REPL" ] && PFX_APPEND=1
  PFX_END=$i
  return 0
}

# --- The command word, as the shell reads it --------------------------------------------------
# Every rule picks its program by the command word, and the shell reads that word before it runs
# it: quotes and backslashes come off (`\git`, `g''h`, `gi"t"`), braces expand (`{gh,pr} merge` is
# `gh pr merge`, `{g..g}h` is `gh`), and a parameter or a substitution becomes its value
# (`G=gh; $G pr merge`). Read as written, each of them left the command to no rule at all, --force
# and --admin included (found 2026-10-01). So a command word holding any of those characters is
# read again (cw_read):
#   - one the guard can read (quotes, backslashes, braces) is replaced by the words the shell makes
#     of it, and the segment is judged again. Once: what that reading leaves (`\"git\"`) is the
#     name, except behind eval, which reads its words again (`eval \$G …`);
#   - a pattern (`/usr/bin/gi[t]`) is judged as each program a rule reads whose name it matches;
#   - a parameter that this same command gives a literal value (`G=gh`, `export G="git -C x"`,
#     `for G in gh git`, `set -- gh …` for "$@") is replaced by each of those values in turn: the
#     guard reads the whole command, so it knows every value the command itself gives the name
#     (cw_assignments). 318 real commands of the 31 days to 2026-10-02 run their program that way;
#   - anything else (a value from a substitution or from the environment, `$1`, `"$@"`, `$(…)`,
#     `${G:-x}`, `$'…'`) cannot be read. Denying it outright would have denied 285 real commands of
#     those 31 days (test harnesses running "$@", `S="python3 $R/x.py"; $S …`, `./$d`), so the
#     guard judges what the word may stand for instead (cw_as_if): nothing (an empty value, or a
#     wrapper, so the next word runs), git, gh and a reader (cat, for the .env rule), and denies,
#     saying so, when any of them is denied. curl is left out on purpose: read as curl, every
#     argument holding a variable would be a destination.
# Only on a segment that is certainly a command. A quoted span may be data, and it keeps being read
# as written: read as the shell reads a command, the grep pattern 'pr-merge\.sh merge|…' is the
# merge step, and a `|parallel|` in an alternation is parallel reading its commands from stdin.
# Certainly commands, though quoted, are a substitution's body (`x="$(cd d && \git push)"`) and
# the script of `bash -c '…'`, `eval '…'` and `ssh host '…'`: the extractor hands those over
# unmarked (see splitSegments and addBodies).
# A path whose directory is filled in (`"$W/scripts/run.sh"`) names its program in its last part,
# which is what every rule reads: it is not an unreadable command word.

# command_word <the word, as written>: CW_EXP is 1 when the last part of its path holds something
# the shell fills in ($NAME, ${…}, $(…), `…`, $'…'), and then CW_VAR is NAME when the whole word is
# one plain parameter ($NAME, ${NAME}, "$NAME", "${NAME}"). Otherwise CW_WORDS are the words the
# shell makes of it (quotes and backslashes removed, braces expanded; of a path, only its last
# part), and CW_OVER is 1 when its braces make more words than the guard reads.
CW_WORDS=()
CW_EXP=0
CW_VAR=""
CW_OVER=0
command_word() {
  local w b
  CW_WORDS=() CW_EXP=0 CW_VAR="" CW_OVER=0
  if [[ "$1" =~ ^\"?\$(\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))\"?$ ]]; then
    CW_VAR="${BASH_REMATCH[2]}${BASH_REMATCH[3]}"
    CW_EXP=1
    return 0
  fi
  # A positional parameter ($@, "$*", $1, ${2}…): what `set --` gives them (see cw_assignments).
  if [[ "$1" =~ ^\"?\$(\{([@*]|[1-9][0-9]*)\}|[@*1-9])\"?$ ]]; then
    CW_VAR="@"
    CW_EXP=1
    return 0
  fi
  # egress_words reads quotes and backslashes as the shell does: an expansion keeps its `$` (or
  # backtick), a literal one becomes \x1f, and an unquoted expansion or brace that expands is
  # marked with \x1e.
  egress_words "$1"
  w="${EGRESS_WORDS[*]-}"
  # base_name, not `${w##*/}`, which took seconds on a 96 KB command word (see base_name).
  base_name "$w"
  b="$BASE_NAME"
  # Whether it holds a `$` or a backtick, \x1e marks or not (not `${b//$'\x1e'/}`: bash replaces
  # thousands of marks in time quadratic in the length of the word).
  if [[ "$b" == *[\$\`]* ]]; then
    CW_EXP=1
    return 0
  fi
  if [[ "$w" == *$'\x1e'* ]]; then
    brace_words "${w//$'\x1e'/}"
    if [ "$BRACE_OVER" -eq 1 ]; then
      CW_OVER=1
      return 0
    fi
    # The shell drops the empty words a brace makes (`{,} git` runs git).
    for w in "${BRACE_OUT[@]}"; do
      w="${w//$'\x1f'/\$}"
      [ -n "$w" ] && CW_WORDS+=("$w")
    done
    # Of a path, its last part names the program; the words the braces add after it are arguments.
    # A quoted name with a blank is no path to cut: it stays whole (cw_read reads it as written).
    if [ "${#CW_WORDS[@]}" -gt 0 ] && [[ "${CW_WORDS[0]}" != *[[:space:]]* ]]; then
      base_name "${CW_WORDS[0]}"
      CW_WORDS[0]="$BASE_NAME"
    fi
    return 0
  fi
  w="${w//$'\x1f'/\$}"
  if [[ "$w" == *[[:space:]]* ]]; then
    CW_WORDS=("$w")
  else
    base_name "$w"
    CW_WORDS=("$BASE_NAME")
  fi
  return 0
}

# cw_value <value of an assignment or a for word, as written>: the value the shell gives, in CWV;
# $'\x1e' when the guard cannot read it (an expansion, a brace, a glob, or empty: an empty value
# leaves the next word to run, which cw_as_if judges anyway).
CWV=""
cw_value() {
  local v
  egress_words "$1"
  v="${EGRESS_WORDS[*]-}"
  if [ -z "$v" ] || [[ "$v" == *$'\x1e'* || "$v" == *[\$\`*?[]* ]]; then
    CWV=$'\x1e'
    return 0
  fi
  CWV="${v//$'\x1f'/\$}"
  return 0
}

# Every value this command gives a name, as "NAME<TAB>VALUE" lines in CW_ASSIGN, read once from all
# its segments: NAME=value and NAME[i]=value (alone, in front of a command, after eval, or after
# export, declare, typeset, local or readonly), the words of `for NAME in …`, and the words of
# `set -- …`, which are the positional parameters ($@, $*, $1…, recorded as `@`). A value the guard
# cannot read is $'\x1e' (cw_value), as is `+=`, a nameref (declare -n: the name stands for another
# one) and every name read, mapfile, readarray and printf -v set.
CW_ASSIGN=""
CW_ASSIGN_READ=0
cw_assignments() {
  local line k n w name plus nameref
  local -a t=()
  [ "$CW_ASSIGN_READ" -eq 1 ] && return 0
  CW_ASSIGN_READ=1
  segment_lines
  for line in ${SEGMENT_LINES[@]+"${SEGMENT_LINES[@]}"}; do
    [[ "$line" == $'\v'* ]] && line="${line:1}"
    [[ "$line" == $'\t'* ]] && line="${line:1}"
    words_of "$line"
    t=(${SPLIT_WORDS[@]+"${SPLIT_WORDS[@]}"})
    n=${#t[@]}
    k=0
    nameref=0
    while [ "$k" -lt "$n" ]; do
      case "${t[k]}" in
        do | then | else | elif | if | while | until | '{' | '!' | coproc | eval | builtin | command) k=$((k + 1)) ;;
        *) break ;;
      esac
    done
    [ "$k" -lt "$n" ] || continue
    case "${t[k]}" in
      set)
        for ((k = k + 1; k < n; k++)); do
          [ "${t[k]}" = -- ] && break
          [[ "${t[k]}" == [-+]* ]] || break
        done
        if [ "${t[k]-}" = -- ]; then
          cw_value "${t[*]:k+1}"
          [ "$k" -lt $((n - 1)) ] || CWV=$'\x1e'
          CW_ASSIGN+="@"$'\t'"${CWV}"$'\n'
        fi
        continue
        ;;
      for)
        name="${t[k + 1]-}"
        [ "${t[k + 2]-}" = in ] || continue
        for ((k = k + 3; k < n; k++)); do
          cw_value "${t[k]}"
          CW_ASSIGN+="${name}"$'\t'"${CWV}"$'\n'
        done
        continue
        ;;
      read | mapfile | readarray)
        for ((k = k + 1; k < n; k++)); do
          [[ "${t[k]}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && CW_ASSIGN+="${t[k]}"$'\t'$'\x1e\n'
        done
        continue
        ;;
      printf)
        for ((k = k + 1; k < n; k++)); do
          case "${t[k]}" in
            -v) CW_ASSIGN+="${t[k + 1]-}"$'\t'$'\x1e\n' ;;
            -v?*) CW_ASSIGN+="${t[k]#-v}"$'\t'$'\x1e\n' ;;
          esac
        done
        continue
        ;;
      export | declare | typeset | local | readonly)
        k=$((k + 1))
        while [ "$k" -lt "$n" ] && [[ "${t[k]}" == [-+]* ]]; do
          [[ "${t[k]}" == -*n* ]] && nameref=1
          k=$((k + 1))
        done
        ;;
    esac
    while [ "$k" -lt "$n" ] && [[ "${t[k]}" =~ ^([A-Za-z_][A-Za-z0-9_]*)(\[[^]]*\])?(\+?)= ]]; do
      name="${BASH_REMATCH[1]}" plus="${BASH_REMATCH[3]}"
      # One shell word: a quoted part with blanks spans several tokens (`G="git -C x"`).
      w="${t[k]}"
      quote_carry "" "$w"
      k=$((k + 1))
      while [ -n "$QC" ] && [ "$k" -lt "$n" ]; do
        w+=" ${t[k]}"
        quote_carry "$QC" "${t[k]}"
        k=$((k + 1))
      done
      cw_value "${w#*=}"
      [ -n "$plus" ] && CWV=$'\x1e'
      [ "$nameref" -eq 1 ] && CWV=$'\x1e'
      CW_ASSIGN+="${name}"$'\t'"${CWV}"$'\n'
    done
  done
  return 0
}

# cw_values <NAME>: the values this command gives NAME, in CWV_LIST; CWV_UNKNOWN is 1 when one of
# them cannot be read, or when the command gives it none (it comes from the environment).
CWV_LIST=()
CWV_UNKNOWN=0
cw_values() {
  local line
  local -a lines=()
  CWV_LIST=()
  CWV_UNKNOWN=0
  cw_assignments
  lines_of "$CW_ASSIGN"
  lines=(${SPLIT_LINES[@]+"${SPLIT_LINES[@]}"})
  for line in ${lines[@]+"${lines[@]}"}; do
    [ "${line%%$'\t'*}" = "$1" ] || continue
    line="${line#*$'\t'}"
    if [ "$line" = $'\x1e' ]; then CWV_UNKNOWN=1; else CWV_LIST+=("$line"); fi
  done
  [ "${#CWV_LIST[@]}" -gt 0 ] || CWV_UNKNOWN=1
  # `${NAME:=value}` and `${NAME=value}` assign it too, wherever they stand.
  [[ "${SEGMENTS:-}" == *'${'"$1"'='* || "${SEGMENTS:-}" == *'${'"$1"':='* ]] && CWV_UNKNOWN=1
  return 0
}

# cw_judge <word>...: judge this segment again with its command word replaced by these words; the
# words in front of it (assignments, wrappers and theirs) and the rest of it stay as written, and so
# do its marks. Reads check_segment's pre_raw, raw, cw_end, QUOTED and PARTIAL.
CW_DEPTH=0
CW_DEPTH_MAX=3
cw_judge() {
  local text="" w
  for w in ${pre_raw[@]+"${pre_raw[@]}"} "$@" "${raw[@]:cw_end}"; do text+="$w "; done
  text="${text% }"
  [ "$PARTIAL" -eq 1 ] && text=$'\t'"$text"
  [ "$QUOTED" -eq 1 ] && text=$'\v'"$text"
  CW_DEPTH=$((CW_DEPTH + 1))
  check_segment "$text"
  CW_DEPTH=$((CW_DEPTH - 1))
  return 0
}

# cw_as_if <the command word, as shown>: judge this segment as each program an unreadable command
# word may stand for (see the top of this section). Not again inside one of them.
CW_ASIF=0
cw_as_if() {
  local cand saved_c="$CW_CONTEXT" saved_h="$CW_HINT"
  CW_ASIF=1
  CW_HINT="write the program's name in the command, or give the name a literal value earlier in this same command (NAME=gh; \$NAME …), which the guard reads"
  for cand in "" git gh cat; do
    if [ -z "$cand" ]; then
      CW_CONTEXT="the program ${1} is filled in by the shell, which the guard cannot read; read as empty (or as a wrapper, so the next word runs), this is denied"
      cw_judge
    else
      CW_CONTEXT="the program ${1} is filled in by the shell, which the guard cannot read; read as ${cand}, this is denied"
      cw_judge "$cand"
    fi
  done
  CW_ASIF=0
  CW_CONTEXT="$saved_c" CW_HINT="$saved_h"
  return 0
}

# The programs some rule reads by its command word (check_segment) and the wrappers prefix_end
# skips: what a pattern in the command word is matched against (cw_read).
CW_RULE_PROGRAMS="git gh curl wget find pr-merge.sh pr_merge.py source bash sh dash zsh ksh ash mksh python python2 python3 export declare typeset readonly local let printf read cat head tail less more grep sed awk strings base64 xxd od tee cp mv rm cd pushd popd env sudo doas nice timeout stdbuf ionice time exec flock chroot caffeinate runuser nsenter unshare strace ltrace watch xargs parallel ssh setsid nohup command builtin busybox eval"

# cw_read: the command word of this segment (raw[0], and the tokens a quoted part with blanks carries
# it over), read as the shell reads it; the segment is judged as what it runs, and CW_DONE is 1: the
# caller is done. CW_DONE 0: the command word is what it says, read on as written. (A flag, not the
# exit status: a function called as a condition runs without `set -e`, and so would every rule.)
CW_DONE=0
cw_read() {
  local w="${raw[0]}" v shown saved="$CW_CONTEXT" ev
  local -a vals=()
  CW_DONE=0
  cw_end=1
  quote_carry "" "$w"
  while [ -n "$QC" ] && [ "$cw_end" -lt "${#raw[@]}" ]; do
    w+=" ${raw[cw_end]}"
    quote_carry "$QC" "${raw[cw_end]}"
    cw_end=$((cw_end + 1))
  done
  command_word "$w"
  shown_subst "$w"
  shown="'${SHOWN}'"
  if [ "$CW_EXP" -eq 0 ]; then
    if [ "$CW_OVER" -eq 1 ]; then
      deny "the command word ${shown}: its braces expand to more words than the guard reads (${BRACE_MAX} at most)" \
        "write the program and its arguments out"
    fi
    # Read on as written when the reading adds nothing or cannot be written back into the segment:
    # the same word, an empty one (`""`: the shell finds no program), or one holding a blank (a
    # quoted program name) or a literal `$`, backtick, backslash, quote or brace: the shell reads a
    # word once, and what one reading leaves (`\"git\"`, `\$G`, `\{a,b\}`) is part of the name. Not
    # after eval, which reads its words once more: `G=gh; eval \$G pr merge 5 --admin` runs gh
    # (found 2026-10-02, verifying this change), so there the reading goes on.
    ev=0
    for v in ${pre_raw[@]+"${pre_raw[@]}"}; do [ "$v" = eval ] && ev=1; done
    for v in ${CW_WORDS[@]+"${CW_WORDS[@]}"}; do
      [[ -z "$v" || "$v" == *[[:space:]]* ]] && return 0
      [ "$ev" -eq 0 ] && [[ "$v" == *[\$\`\\\'\"\{]* ]] && return 0
    done
    # A pattern in the program's name (`/usr/bin/gi[t]`, `/usr/bin/g?t`) is the file it matches:
    # judged as each program a rule reads whose name it matches. One that matches none of them runs
    # nothing a rule reads, and is read as written (`[ -f x ]`, `./run-*.sh`). So is one with no
    # arguments: a `case` arm's pattern (`*)`, `[a-z]*)`) arrives as a segment of its own, and 120
    # real commands of the 31 days to 2026-10-02 hold one; a program run bare does nothing any rule
    # denies but read commands from stdin (parallel), which a pattern for it would be a long way to.
    if [[ "${CW_WORDS[0]-}" == *[\*\?\[]* ]] && { [ "${#CW_WORDS[@]}" -gt 1 ] || [ "$cw_end" -lt "${#raw[@]}" ]; }; then
      for v in $CW_RULE_PROGRAMS; do
        # shellcheck disable=SC2053 # matching the pattern is the point
        [[ "$v" == ${CW_WORDS[0]} ]] || continue
        CW_CONTEXT="the program ${shown} is a pattern the shell fills in with a file's name; read as ${v}, this is denied"
        cw_judge "$v" "${CW_WORDS[@]:1}"
        CW_DONE=1
      done
      CW_CONTEXT="$saved"
      return 0
    fi
    base_name "${tok[0]}"
    if [ "$cw_end" -eq 1 ] && [ "${#CW_WORDS[@]}" -eq 1 ] && [ "${CW_WORDS[0]}" = "$BASE_NAME" ]; then return 0; fi
    cw_judge ${CW_WORDS[@]+"${CW_WORDS[@]}"}
    CW_DONE=1
    return 0
  fi
  if [ -n "$CW_VAR" ]; then
    cw_values "$CW_VAR"
    for v in ${CWV_LIST[@]+"${CWV_LIST[@]}"}; do
      CW_CONTEXT="${shown} is '${v}' in this command"
      words_of "$v"
      vals=(${SPLIT_WORDS[@]+"${SPLIT_WORDS[@]}"})
      cw_judge ${vals[@]+"${vals[@]}"}
    done
    CW_CONTEXT="$saved"
    CW_DONE=1
    [ "$CWV_UNKNOWN" -eq 1 ] || return 0
  fi
  # Inside one of the readings of cw_as_if, a second unreadable word is read as written.
  [ "$CW_ASIF" -eq 0 ] || return 0
  cw_as_if "$shown"
  CW_DONE=1
  return 0
}

# find runs the command after -exec, -execdir, -ok and -okdir (up to `;`, or a `+` right after `{}`)
# once per file it finds, with the file's name where `{}` stands: that command is judged like one
# xargs -I{} runs, `{}` being a value filled in later. Until 2026-10-02, `find . -exec gh pr merge
# 5 --admin \;` reached no rule.
check_find_exec() {
  local k=1 n=${#tok[@]} start text
  while [ "$k" -lt "$n" ]; do
    unquoted "${raw[k]}"
    case "$UNQUOTED" in
      -exec | -execdir | -ok | -okdir)
        start=$((k + 1))
        text=""
        for ((k = start; k < n; k++)); do
          unquoted "${raw[k]}"
          [ "$UNQUOTED" = ";" ] && break
          [ "$UNQUOTED" = "+" ] && [ "$k" -gt "$start" ] && [ "${tok[k - 1]}" = "{}" ] && break
          text+="${raw[k]} "
        done
        if [ -n "$text" ]; then
          text="xargs -I{} ${text% }"
          [ "$PARTIAL" -eq 1 ] && text=$'\t'"$text"
          [ "$QUOTED" -eq 1 ] && text=$'\v'"$text"
          check_segment "$text"
        fi
        ;;
    esac
    k=$((k + 1))
  done
  return 0
}

# GNU parallel (a wrapper, see prefix_end) runs its command once per input: the words after ::: (or
# :::+), the lines of the files after :::: (or ::::+), or the lines it reads. The words after :::
# are read as arguments appended to the command, which is what parallel does with one input and
# what it does with each of several. With no command, the inputs ARE the commands
# (parallel_commands); lines read from stdin or a file cannot be read, so that is denied. CW_DONE is
# 1 when the segment was judged here.
# Each command parallel runs is a process of its own: a cd in one (`parallel 'cd {} && …' ::: <dir>`)
# moves its own git commands (parallel_job) and nothing after it, so the ones judging it records are
# dropped (seg_cds_keep). Until 2026-10-03 they stood at the place of the parallel and moved the git
# commands after it (found verifying #299: a lease push to the agent's own branch denied as one
# toward develop).
parallel_inputs() {
  local k n=${#raw[@]} sep=0 groups=0 plain=1 w repl="$PFX_REPL" ncds=${#SEG_CDS[@]}
  local -a rest=() cmd=() inputs=() each=()
  CW_DONE=0
  unquoted "${raw[0]}"
  case "$UNQUOTED" in
    ::: | :::+)
      parallel_commands
      seg_cds_keep "$ncds"
      CW_DONE=1
      return 0
      ;;
    :::: | ::::+) deny_parallel_input ;;
  esac
  for ((k = 1; k < n; k++)); do
    unquoted "${raw[k]}"
    case "$UNQUOTED" in
      ::: | :::+ | :::: | ::::+)
        sep=1
        groups=$((groups + 1))
        [ "$UNQUOTED" = ::: ] || plain=0
        ;;
      *)
        rest+=("${raw[k]}")
        if [ "$sep" -eq 0 ]; then cmd+=("${raw[k]}"); else inputs+=("${raw[k]}"); fi
        ;;
    esac
  done
  [ "$sep" -eq 1 ] || return 0
  # With its replace string in the command (`parallel gh api -X DELETE {} ::: <endpoint>`), parallel
  # puts each input there and appends nothing: each command it runs is judged, when the inputs are
  # one group of plain words, at most 16 (found 2026-10-03, verifying this change: read as appended
  # to the command, the endpoint written after ::: was not the endpoint).
  if [ -n "$PFX_REPL" ] && [ "$groups" -eq 1 ] && [ "$plain" -eq 1 ] && [ "${#inputs[@]}" -gt 0 ] && [ "${#inputs[@]}" -le 16 ] \
    && [[ " ${raw[0]} ${cmd[*]-} " == *"$PFX_REPL"* ]]; then
    for w in "${inputs[@]}"; do
      case "$w" in *[\'\"\\\$\`]*) plain=0 ;; esac
    done
  else
    plain=0
  fi
  if [ "$plain" -eq 1 ]; then
    cmd=("${raw[0]}" ${cmd[@]+"${cmd[@]}"})
    for w in "${inputs[@]}"; do
      each=()
      for k in "${cmd[@]}"; do each+=("${k//"$repl"/$w}"); done
      raw=("${each[@]}")
      cw_end=${#raw[@]}
      cw_judge "${each[@]}"
      parallel_job "${each[@]}"
      seg_cds_keep "$ncds"
    done
    CW_DONE=1
    return 0
  fi
  raw=("${raw[0]}" ${rest[@]+"${rest[@]}"})
  cw_end=1
  cw_judge "${raw[0]}"
  seg_cds_keep "$ncds"
  CW_DONE=1
  return 0
}
# seg_cds_keep <n>: SEG_CDS back to its first n directory changes.
seg_cds_keep() {
  SEG_CDS=(${SEG_CDS[@]+"${SEG_CDS[@]:0:$1}"})
  return 0
}
# parallel_job <word>...: one command parallel runs, with its input in place, judged as the shell
# parallel hands it to reads it when it holds several (`'cd {} && git push …'`): one by one, a cd
# in one counting for the git commands after it in the job, and for nothing after the job (the
# caller drops it). The job split at the operators that stand as words of their own.
parallel_job() {
  local w part="" text="$*"
  local -a toks=()
  case "$text" in
    \'*\' | \"*\") text="${text:1:${#text}-2}" ;;
  esac
  [[ "$text" == *'&&'* || "$text" == *'||'* || "$text" == *';'* || "$text" == *'|'* ]] || return 0
  words_of "$text"
  toks=(${SPLIT_WORDS[@]+"${SPLIT_WORDS[@]}"})
  for w in ${toks[@]+"${toks[@]}"}; do
    case "$w" in
      '&&' | '||' | ';' | '|')
        parallel_job_part "$part"
        part=""
        ;;
      *';')
        parallel_job_part "$part ${w%;}"
        part=""
        ;;
      *) part+=" $w" ;;
    esac
  done
  parallel_job_part "$part"
}
parallel_job_part() {
  local part="${1# }"
  [ -n "$part" ] || return 0
  # Each part is judged as a segment of its own, so the judge's time limit holds here too (#302: a
  # job of 5000 parts took 6 s).
  check_deadline
  [ "$QUOTED" -eq 1 ] && part=$'\v'"$part"
  CW_DEPTH=$((CW_DEPTH + 1))
  check_segment "$part"
  CW_DEPTH=$((CW_DEPTH - 1))
  return 0
}

# parallel with no command, its inputs after ::: in raw: each input is a command, as the shell
# reads the word (`parallel ::: 'gh pr merge 5 --admin'`, `parallel ::: git\ push\ …`), and with
# several groups of inputs parallel joins one word of each into the command, so all of them
# together are judged as one too.
parallel_commands() {
  local w groups=0
  local -a words=()
  egress_words "${raw[*]}"
  for w in ${EGRESS_WORDS[@]+"${EGRESS_WORDS[@]}"}; do
    w="${w//$'\x1e'/}"
    w="${w//$'\x1f'/\$}"
    case "$w" in
      ::: | :::+)
        groups=$((groups + 1))
        continue
        ;;
      :::: | ::::+) deny_parallel_input ;;
    esac
    words+=("$w")
  done
  for w in ${words[@]+"${words[@]}"}; do check_segment "$w"; done
  [ "$groups" -le 1 ] || check_segment "${words[*]}"
  return 0
}

# Is parallel asked about itself (--version, --help, --citation…), so it runs nothing? Reads tok.
parallel_info_only() {
  local w
  for w in "${tok[@]}"; do
    case "$w" in
      --version | -V | --help | -h | --citation | --bibtex | --number-of-* | --minversion* | --max-line-length-allowed | --record-env | --embed) return 0 ;;
    esac
  done
  return 1
}

deny_parallel_input() {
  deny "parallel with no command runs the lines it reads (from stdin, or from the files after ::::) as commands, which the guard cannot read" \
    "write the command after parallel's options (parallel <command> ::: <inputs>), or run the commands one by one"
}

SEG_XARGS=0
SEG_REPL=""
SEG_APPEND=0
check_segment() {
  local seg="$1" PARTIAL=0 QUOTED=0 cw_end=1
  local -a raw=() tok=() pre_raw=()
  local t
  # The text of a quoted span (see splitSegments): marked with a leading vertical tab.
  case "$seg" in
    $'\v'*)
      QUOTED=1
      seg="${seg:1}"
      ;;
  esac
  # Half a command, cut at a substitution (see splitSegments): marked with a leading TAB.
  case "$seg" in
    $'\t'*)
      PARTIAL=1
      seg="${seg:1}"
      ;;
  esac

  # Simple whitespace tokenization: quotes are NOT interpreted (tripwire); they
  # are only stripped from the ends of each token.
  words_of "$seg"
  raw=(${SPLIT_WORDS[@]+"${SPLIT_WORDS[@]}"})
  if [ "${#raw[@]}" -eq 0 ]; then return 0; fi
  # One quote off each end, tested first: `${t#\"}` and `${t%\"}` take time quadratic in the length of
  # the word, even when there is nothing to take off (a word of 400 KB took seconds).
  for t in "${raw[@]}"; do
    [[ "$t" == \"* ]] && t="${t:1}"
    [[ "$t" == *\" ]] && t="${t:0:${#t}-1}"
    [[ "$t" == \'* ]] && t="${t:1}"
    [[ "$t" == *\' ]] && t="${t:0:${#t}-1}"
    tok+=("$t")
  done

  # A previous segment's git options must not leak into this one.
  GIT_GLOBALS=()

  # Skip what is not the command word: assignments, shell keywords (do/then/… appear as segment
  # heads when loops and conditionals are split by ';'), a group `{ … }`, a negation `!`, `coproc`
  # and the wrappers with their options (see prefix_end).
  PFX_W=("${tok[@]}")
  PFX_RAW=("${raw[@]}")
  prefix_end
  SEG_XARGS=$PFX_XARGS
  SEG_REPL=$PFX_REPL
  SEG_APPEND=$PFX_APPEND
  # Before the command word is cut out: an assignment can be the whole segment.
  check_ci_identity_prefix
  if [ "$PFX_END" -ge "${#tok[@]}" ]; then
    [ "$PFX_PARALLEL" -eq 1 ] && [ "$QUOTED" -eq 0 ] && ! parallel_info_only && deny_parallel_input
    return 0
  fi
  pre_raw=("${raw[@]:0:PFX_END}")
  tok=("${tok[@]:PFX_END}")
  raw=("${raw[@]:PFX_END}")

  # The command word as the shell reads it, and parallel's inputs (see cw_read and
  # parallel_inputs), on a segment that is certainly a command: not on a quoted span, which may be
  # data (see splitSegments).
  # Past CW_DEPTH_MAX readings, behind eval (`eval eval eval \\\\\\\\git …`: each eval takes one
  # layer of backslashes off), a command word that still holds what the shell reads again is not
  # read as written, which would be a way around every rule: it is denied.
  if [ "$QUOTED" -eq 0 ] && [ "$CW_DEPTH" -ge "$CW_DEPTH_MAX" ] && [[ " ${pre_raw[*]-} " == *" eval "* ]]; then
    case "${raw[0]}" in
      *[\\\'\"\$\`\{]*)
        deny "the command word '${raw[0]}' is read through more layers of quoting or expansion than the guard follows (${CW_DEPTH_MAX})" \
          "write the program's name plainly, once"
        ;;
    esac
  fi
  if [ "$QUOTED" -eq 0 ] && [ "$CW_DEPTH" -lt "$CW_DEPTH_MAX" ]; then
    if [ "$PFX_PARALLEL" -eq 1 ]; then
      parallel_inputs
      [ "$CW_DONE" -eq 0 ] || return 0
    fi
    case "${raw[0]}" in
      *[\\\'\"\$\`\{\*\?\[]*)
        cw_read
        [ "$CW_DONE" -eq 0 ] || return 0
        ;;
    esac
  fi

  local cmd0="${tok[0]}"
  base_name "$cmd0" # in case it is invoked with an absolute path (/usr/bin/curl)
  cmd0="$BASE_NAME"

  # Where the next git command runs (see command_git_dir): every directory change, in order, as
  # "<position>\t<scopes>\t<cd|pushd|popd>\t<target>" (see SEG_POS_O). One in a quoted span that may
  # be data (`echo "cd /tmp"`) stands in that span's own scope, so it moves only what the span holds.
  case "$cmd0" in
    cd | pushd)
      local target="" k
      for ((k = 1; k < ${#tok[@]}; k++)); do
        case "${tok[k]}" in
          --) target="${tok[k + 1]-}"; break ;;
          -L | -P | -e | -@) ;;
          *) target="${tok[k]}"; break ;;
        esac
      done
      # `cd` alone goes home (`pushd` alone swaps the top two of the stack: not followed); a
      # target that is cut (half a command) cannot be followed.
      if [ "$k" -ge "${#tok[@]}" ]; then
        target="~"
        [ "$cmd0" = pushd ] && target=""
      fi
      [ "$PARTIAL" -eq 1 ] && target=""
      SEG_CDS+=("${SEG_POS_O}"$'\t'"${SEG_POS_P}"$'\t'"${cmd0}"$'\t'"${target}")
      ;;
    popd)
      # `popd +N`, `popd -n`… do not return to the top of the stack: not followed.
      if [ "${#tok[@]}" -gt 1 ]; then
        SEG_CDS+=("${SEG_POS_O}"$'\t'"${SEG_POS_P}"$'\tcd\t')
      else
        SEG_CDS+=("${SEG_POS_O}"$'\t'"${SEG_POS_P}"$'\tpopd\t')
      fi
      ;;
  esac

  # Redirections into a generated tree: apply to any command.
  check_generated_redirect "$seg"

  case "$cmd0" in
    git) check_git ;;
    gh) check_gh ;;
    curl | wget) check_egress ;;
    find) check_find_exec ;;
    pr-merge.sh | pr_merge.py | source | . | bash | sh | dash | zsh | ksh | ash | mksh | python | python[0-9]*)
      check_mwg_merge
      ;;
    export | declare | typeset | readonly | local | let | printf | read) check_ci_identity_builtin ;;
  esac

  # `source .env` and `. .env` load the file into the shell without printing it, and are not denied
  # on purpose: a script that loads its own variables is the ordinary use, and what this rule keeps
  # out is the secrets in the transcript (decided 2026-10-04, #306). Printing what was loaded takes
  # one of the commands below, or env, and those stay judged.
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

# judge_segments <the extractor's output>: each segment judged in turn. A position line ("\x01<o>
# <p>", see "Where each segment stands" in EXTRACT_JS) sets where the segments after it stand. Only
# this loop reads them, and only in their exact shape: a segment never starts with the mark (the
# extractor puts a blank in front of one that does), and check_segment, which also judges what a
# segment runs later (a `gh alias set` expansion, parallel's inputs, a command word read again), never
# reads one, so no text inside a command can stand for one (found 2026-10-03, verifying this change).
SEG_POS_RE='^([0-9]+(\.[0-9]+)*|!)\ (/[0-9.qhvc/]*)$'
judge_segments() {
  local line
  local -a lines=()
  if [ "$1" = "${SEGMENTS:-}" ]; then
    segment_lines
    lines=(${SEGMENT_LINES[@]+"${SEGMENT_LINES[@]}"})
  else
    lines_of "$1"
    lines=(${SPLIT_LINES[@]+"${SPLIT_LINES[@]}"})
  fi
  for line in ${lines[@]+"${lines[@]}"}; do
    check_deadline
    if [[ "$line" == $'\x01'* ]] && [[ "${line#$'\x01'}" =~ $SEG_POS_RE ]]; then
      SEG_POS_O="${BASH_REMATCH[1]}"
      SEG_POS_P="${BASH_REMATCH[3]}"
      continue
    fi
    check_segment "$line"
  done
}

# --- Command extraction from the harness JSON -------------------------------
# node parses the JSON (no jq: not guaranteed on the machine; node >= 24 is a
# repo requirement), drops heredoc bodies that are DATA (commit messages, files
# written with cat > f <<EOF — analyzing them would give false positives) but
# KEEPS the ones fed to a shell (bash <<EOF: that is code), and splits the
# command into segments by shell operators, one per line.

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

// Heredoc bodies are data — commit messages, files written with `cat > f <<EOF` — and
// analyzing them as commands would deny a runbook for mentioning `git push origin main` in
// its prose. BUT a heredoc fed to a SHELL is code: `bash <<'EOF' … EOF`, `cat <<EOF | sh`,
// `ssh host <<EOF`, `sudo -s <<EOF`. Dropping a body without asking where it goes takes every
// rule out of it; keeping every body denies prose for quoting a command. Both directions are
// defects, and the suite carries one case per shape — that is where the concrete forms live.
//
// So a body is KEPT for analysis when it reaches a shell that will read it as commands, and
// dropped otherwise. "Reaches a shell" is decided on the COMMAND STRUCTURE of the line that
// opens the heredoc, never on words appearing in it: a shell name inside a PR title is prose,
// and a shell reached through a path, a variable or a wrapper is still a shell. So:
//   * the opener is the LOGICAL line (backslash-newline joined, comments removed);
//   * within it, only the PIPELINE holding the `<<` matters, from the stage that owns the
//     heredoc onward (in `cat <<EOF | bash` the body flows into bash through the pipe);
//   * a stage feeds a shell when its command word — after wrappers like sudo/env/nice/ssh/su
//     are unwrapped, path stripped, quotes removed — is a shell that reads its script from
//     stdin (no `-c`, or `-s`, or `/dev/stdin`), or `.`/`source /dev/stdin`, or a wrapper that
//     spawns a shell when given no command (`sudo -s`, `su -`, `ssh host`, `chroot dir`);
//   * a command word that is an EXPANSION (`$SHELL`, `"$(which bash)"`) cannot be known and
//     fails CLOSED: the body is analyzed;
//   * a heredoc inside `$( … )` / `<( … )` / backticks reaches a shell when the enclosing
//     command is `eval`, `.`/`source`, or a shell (`bash -c "$(cat <<EOF …)"`);
//   * interpreters that are not shells (python, node, psql, make) are not parsed — the guard
//     never read them, and a script file would carry the same text. Documented residual risk.
// A kept body goes through the same treatment recursively (a heredoc inside it feeds a shell
// or not by the same rule), depth-capped so a pathological nesting cannot hang the hook.
// The lookaround in the operator regex avoids confusing here-strings (<<<) with heredocs; a
// here-string stays in its segment and is analyzed there.
const SHELLS = new Set(["bash", "sh", "dash", "zsh", "ksh", "ash", "mksh", "fish"]);
const STDIN_PATHS = new Set(["/dev/stdin", "/dev/fd/0", "/proc/self/fd/0", "-"]);
const WRAPPERS = new Set(["env", "nice", "nohup", "time", "timeout", "command", "exec", "stdbuf",
  "ionice", "setsid", "caffeinate", "chroot", "nsenter", "unshare", "flock", "strace", "ltrace", "busybox"]);
const CONTAINERS = new Set(["docker", "podman", "nerdctl", "kubectl", "lxc", "incus", "vagrant", "machinectl"]);
// Words that can precede the command word of a stage without being it.
const RESERVED = new Set(["!", "if", "then", "else", "elif", "do", "while", "until", "{", "coproc", "time", "--"]);
// Flags that TAKE A VALUE, per wrapper: the value is not the command word.
const VALUE_FLAGS = {
  sudo: new Set(["-u", "-g", "-h", "-p", "-a", "-c", "-C", "-U", "-r", "-t", "-T", "-D", "-R"]),
  doas: new Set(["-u", "-C"]),
  runuser: new Set(["-u", "-g", "-G", "-c", "-s", "--shell", "--user", "--group", "--command"]),
  su: new Set(["-c", "-s", "-g", "-G", "--command", "--shell", "--group", "--supp-group"]),
  ssh: new Set(["-p", "-l", "-i", "-o", "-F", "-J", "-L", "-R", "-D", "-W", "-E", "-b", "-c", "-m", "-e", "-I", "-O", "-Q", "-S", "-w", "-B", "-P"]),
  timeout: new Set(["-s", "-k", "--signal", "--kill-after"]),
  nice: new Set(["-n", "--adjustment"]),
  flock: new Set(["-w", "-E", "--timeout", "--conflict-exit-code"]),
  nsenter: new Set(["-t", "-S", "-G", "-r", "-w", "--target"]),
  unshare: new Set(["-s", "-R", "-w", "--setgroups", "--root", "--wd"]),
  env: new Set(["-u", "--unset", "-C", "--chdir", "-S", "--split-string"]),
  stdbuf: new Set(["-i", "-o", "-e"]),
  ionice: new Set(["-c", "-n", "-p"]),
  strace: new Set(["-o", "-e", "-p", "-s", "-E", "-a", "-P", "-I", "-u"]),
  ltrace: new Set(["-o", "-e", "-p", "-s", "-u"]),
  exec: new Set(["-a"]),
  chroot: new Set(["--userspec", "--groups"]),
};

function basename(t) { const i = t.lastIndexOf("/"); return i === -1 ? t : t.slice(i + 1); }
const isSpace = (c) => c === " " || c === "\t" || c === "\n" || c === "\r";

// Quote-aware word tokenizer for ONE simple command (a stage: no unquoted |, ;, &&, newline —
// hitting one STOPS the tokenizer, and it must never loop: a tokenizer that does not advance
// hangs the hook, and a hook that cannot finish analyses nothing — so non-advance is a defect
// of the same class as a missing rule, not a slowdown).
// Words are {text, hasExpansion, quoted, qstart}: text is the unquoted content; hasExpansion
// marks an unquoted `$`/backtick or a `$` inside double quotes; quoted means some part was
// quoted; qstart means the word STARTED with a quote (so `"A=b"` is not an assignment).
// Redirections — including the heredoc operator and its delimiter, and here-strings with
// their word — are dropped: they are not command words.
function tokenize(str) {
  const words = [];
  let i = 0;
  const n = str.length;
  while (i < n) {
    while (i < n && isSpace(str[i])) i++;
    if (i >= n) break;
    const c = str[i];
    if (c === "#") break;                                          // comment: not code
    if (c === "|" || c === ";" || c === "&" || c === ")" || c === "(") break;   // not a simple command any more
    const rm = /^(?:\d*>&\d*|\d*<&\d*|&>>?|\d*>>?\|?|\d*<<<|\d*<<-?|\d*<>|\d*<)/.exec(str.slice(i));
    if (rm && rm[0].length) {
      i += rm[0].length;
      if (/[<>]&\d+$/.test(rm[0]) || /[<>]&-$/.test(rm[0])) continue;   // 2>&1, 2>&-: no target word
      while (i < n && isSpace(str[i])) i++;
      const before = i; readWord(); if (i === before) i++;         // the target, skipped
      continue;
    }
    const before = i;
    const w = readWord();
    if (i === before) { i++; continue; }                           // progress, always
    words.push(w);
  }
  return words;

  function readWord() {
    let text = "", hasExpansion = false, quoted = false, qstart = false;
    const w0 = i;
    while (i < n) {
      const c = str[i];
      if (isSpace(c) || c === "|" || c === ";" || c === "&" || c === ")" || c === "(" || c === "<" || c === ">") break;
      if (c === "'") { quoted = true; if (i === w0) qstart = true; i++; while (i < n && str[i] !== "'") text += str[i++]; i++; continue; }
      if (c === '"') {
        quoted = true; if (i === w0) qstart = true; i++;
        while (i < n && str[i] !== '"') {
          if (str[i] === "\\" && i + 1 < n) { text += str[i + 1]; i += 2; continue; }
          if (str[i] === "$" || str[i] === "`") hasExpansion = true;
          if (str[i] === "$" && str[i + 1] === "(") { i = skipParens(i + 1); continue; }
          if (str[i] === "`") { i++; while (i < n && str[i] !== "`") i++; i++; continue; }
          text += str[i++];
        }
        i++;
        continue;
      }
      if (c === "\\" && i + 1 < n) { text += str[i + 1]; i += 2; continue; }
      if (c === "$" || c === "`") {
        hasExpansion = true;
        if (c === "$" && str[i + 1] === "(") { i = skipParens(i + 1); continue; }
        if (c === "$" && str[i + 1] === "{") { i++; while (i < n && str[i] !== "}") i++; i++; continue; }
        if (c === "`") { i++; while (i < n && str[i] !== "`") i++; i++; continue; }
      }
      text += c; i++;
    }
    return { text, hasExpansion, quoted, qstart };
  }
  function skipParens(at) {                                        // at points at "(": index past the matching ")"
    let depth = 0, j = at, q = null;
    for (; j < n; j++) {
      const c = str[j];
      if (q) { if (c === q) q = null; else if (c === "\\" && q === '"') j++; continue; }
      if (c === "'" || c === '"') { q = c; continue; }
      if (c === "(") depth++;
      else if (c === ")") { depth--; if (depth === 0) return j + 1; }
    }
    return n;
  }
}

// Lexer over one logical line. Calls cb(j, tok, depth, frameStart) for every character outside
// quotes: tok is the character, or "$(" / "(" for a frame opening at j (frames: `$(`, `<(`,
// `>(`, backticks, plain `(`, and `{ … }` groups) and ")" for a frame closing (frameStart = where
// it opened). Inside double quotes only `$(` and backticks open a frame, and the quoting state
// is restored when it closes. Returns the state at the end: {depth, q}.
function lex(line, cb) {
  const stack = [];
  let q = null;
  const isWordEdge = (c) => c === undefined || isSpace(c) || c === ";" || c === "|" || c === "&" || c === "(" || c === ")";
  for (let j = 0; j < line.length; j++) {
    const c = line[j], nx = line[j + 1], pv = line[j - 1];
    if (q === "'") { if (c === "'") q = null; continue; }
    if (q === '"') {
      if (c === "\\") { j++; continue; }
      if (c === '"') { q = null; continue; }
      if (c === "$" && nx === "(") { stack.push({ j, q, kind: "$(" }); q = null; cb(j, "$(", stack.length, j); j++; continue; }
      if (c === "`") { stack.push({ j, q, kind: "`" }); q = null; cb(j, "$(", stack.length, j); continue; }
      continue;
    }
    if (c === "\\") { j++; continue; }
    if (c === "'" || c === '"') { q = c; continue; }
    if (c === "`") {
      if (stack.length && stack[stack.length - 1].kind === "`") { const f = stack.pop(); q = f.q; cb(j, ")", stack.length, f.j); }
      else { stack.push({ j, q: null, kind: "`" }); cb(j, "$(", stack.length, j); }
      continue;
    }
    if (c === "$" && nx === "{") { j++; while (j < line.length && line[j] !== "}") j++; continue; }   // ${…}: not a group
    if ((c === "$" || c === "<" || c === ">") && nx === "(") { stack.push({ j, q: null, kind: "$(" }); cb(j, "$(", stack.length, j); j++; continue; }
    if (c === "(") { stack.push({ j, q: null, kind: "(" }); cb(j, "(", stack.length, j); continue; }
    if (c === ")") { const f = stack.pop(); if (f) { q = f.q; cb(j, ")", stack.length, f.j); } continue; }
    if (c === "{" && isWordEdge(pv) && isSpace(nx)) { stack.push({ j, q: null, kind: "{" }); cb(j, "(", stack.length, j); continue; }
    if (c === "}" && isWordEdge(pv) && isWordEdge(nx) && stack.length && stack[stack.length - 1].kind === "{") {
      const f = stack.pop(); cb(j, ")", stack.length, f.j); continue;
    }
    cb(j, c, stack.length, -1);
  }
  return { depth: stack.length, q };
}

// Is a quote or a frame still open at the end of this text? Then the command continues AFTER
// the heredoc terminator (`echo "$(cat <<EOF` … `EOF` … `)" | sh`, `{ cat <<EOF` … `} | bash`).
function openAtEnd(text) {
  const st = lex(text, () => {});
  return st.depth > 0 || st.q !== null;
}

// Split a command string into its simple commands at unquoted, depth-0 list and pipe operators.
function splitList(text) {
  const parts = [];
  let last = 0, skip = -1;
  lex(text, (j, tok, depth) => {
    if (depth !== 0 || tok.length !== 1 || j === skip) return;
    const nx = text[j + 1], pv = text[j - 1];
    if (tok === ";" || tok === "\n") { parts.push(text.slice(last, j)); last = j + 1; return; }
    if (tok === "|" || tok === "&") {
      if (tok === "&" && (pv === ">" || pv === "<" || nx === ">")) return;      // 2>&1, &>
      let w = 1;
      if (nx === tok) w = 2;
      else if (tok === "|" && nx === "&") w = 2;
      parts.push(text.slice(last, j)); last = j + w; skip = j + 1;
    }
  });
  parts.push(text.slice(last));
  return parts.filter((p) => p.trim());
}

// Does ANY simple command of this string hand its stdin to a shell? (Remote/-c command lines:
// every command of the list inherits the same stdin, and a pipe carries it further.)
function anyFeedsShell(text, depth) {
  return splitList(text).some((part) => wordsFeedShell(tokenize(part), depth));
}

// Is this script argument stdin? An expansion that is the whole word cannot be known → closed.
function scriptArgIsStdin(p) {
  if (p.hasExpansion && p.text === "") return true;
  return STDIN_PATHS.has(p.text);
}

// Does a shell invoked with these arguments read its script from stdin? Flags count whether
// quoted or not (`bash '-s'` is still -s to bash); `-s` means stdin even with positionals
// after it (`bash -s deploy`: deploy is $1); `-c` means the script is an argument; a cluster
// ending in o/O eats the next word (`-euo pipefail`); `-n` parses without executing.
function shellReadsStdin(args) {
  let hasC = false, hasS = false, hasN = false;
  for (let k = 0; k < args.length; k++) {
    const a = args[k], t = a.text;
    if (t === "--") { if (hasN) return false; if (hasS) return true; const p = args[k + 1]; return !p || scriptArgIsStdin(p); }
    if ((t.startsWith("-") || t.startsWith("+")) && t.length > 1) {
      if (t.startsWith("--")) { if (t === "--rcfile" || t === "--init-file") k++; continue; }
      if (/[oO]$/.test(t)) k++;
      if (t.includes("c")) hasC = true;
      if (t.includes("s")) hasS = true;
      if (t.includes("n")) hasN = true;
      continue;
    }
    if (hasN) return false;
    if (hasS) return true;
    if (hasC) return false;
    return scriptArgIsStdin(a);
  }
  return !hasN && (hasS || !hasC);
}

// Strip `-x` / `-x value` / `--long[=v]` / `--` from the front of a wrapper's args.
function skipFlags(name, args) {
  const valued = VALUE_FLAGS[name] || new Set();
  let k = 0;
  while (k < args.length) {
    const a = args[k], t = a.text;
    if (a.hasExpansion && t === "") break;                            // `sudo $FLAGS …`: unknown
    if (t === "--") { k++; break; }
    if (t === "-") { k++; continue; }                                 // `su -`
    if (!t.startsWith("-")) break;
    if (valued.has(t) || (name === "ssh" && t.length === 2 && /^-[plioFJLRDWEbcmeIOQSwBP]$/.test(t))) { k += 2; continue; }
    k++;
  }
  return args.slice(k);
}

function sudoWantsShell(name, args) {
  const valued = VALUE_FLAGS[name] || new Set();
  for (let k = 0; k < args.length; k++) {
    const t = args[k].text;
    if (!t.startsWith("-")) break;
    if (t === "--shell" || t === "--login") return true;
    if (valued.has(t)) { k++; continue; }
    if (/^-[A-Za-z]*[si]/.test(t) && !t.startsWith("--")) return true;
  }
  return false;
}

// The remote/-c command line, rebuilt from its words: a single quoted word IS the line.
function commandLineOf(words) {
  if (words.length === 1) return words[0].text;
  return words.map((w) => w.text).join(" ");
}

// Does this simple command, given a heredoc (or its pipe) on stdin, hand that text to a shell as
// commands? Wrappers are unwrapped; a command word that is an expansion fails closed.
function wordsFeedShell(words, depth) {
  if (depth > 12) return true;
  let i = 0;
  while (i < words.length && ((RESERVED.has(words[i].text) && !words[i].quoted) || (/^[A-Za-z_][A-Za-z0-9_]*=/.test(words[i].text) && !words[i].qstart))) i++;
  if (i >= words.length) return false;
  const w0 = words[i];
  const rest = words.slice(i + 1);
  const name = basename(w0.text);
  if (w0.hasExpansion && !SHELLS.has(name)) return true;             // `$SHELL <<EOF`, `"$(which bash)" <<EOF`, `$BIN/tool <<EOF`
  if (SHELLS.has(name)) return shellReadsStdin(rest);
  if (name === "." || name === "source") return rest.length === 0 || scriptArgIsStdin(rest[0]);
  if (name === "ssh") {
    const r = skipFlags("ssh", rest);                                // r[0] = host, the rest = remote command
    if (r.length && r[0].hasExpansion && r[0].text === "") return true;
    const cmd = r.slice(1);
    if (!cmd.length) return true;                                    // remote login shell reads stdin
    if (cmd.some((w) => w.hasExpansion && w.text === "")) return true;
    return anyFeedsShell(commandLineOf(cmd), depth + 1);
  }
  if (name === "su") {
    const c = rest.findIndex((a) => a.text === "-c" || a.text === "--command");
    if (c >= 0 && rest[c + 1]) return (rest[c + 1].hasExpansion && rest[c + 1].text === "") ? true : anyFeedsShell(rest[c + 1].text, depth + 1);
    return true;                                                     // `su`, `su -`, `su - user`: a shell on stdin
  }
  if (name === "sudo" || name === "doas") {
    const cmd = skipFlags(name, rest);
    if (cmd.length) return wordsFeedShell(cmd, depth + 1);
    return sudoWantsShell(name, rest);                               // `sudo -s` / `sudo -i` / `doas -s` alone
  }
  if (name === "runuser") {
    const c = rest.findIndex((a) => a.text === "-c" || a.text === "--command");
    if (c >= 0 && rest[c + 1]) return (rest[c + 1].hasExpansion && rest[c + 1].text === "") ? true : anyFeedsShell(rest[c + 1].text, depth + 1);
    const hasU = rest.some((a) => a.text === "-u" || a.text === "--user");
    const cmd = skipFlags("runuser", rest);
    if (hasU) return cmd.length ? wordsFeedShell(cmd, depth + 1) : true;   // `runuser -u x -- CMD`
    return true;                                                     // `runuser -l x`, `runuser - x [args]`: x's shell
  }
  if (name === "env") {
    const sIdx = rest.findIndex((a) => a.text === "-S" || a.text === "--split-string");
    if (sIdx >= 0 && rest[sIdx + 1]) return anyFeedsShell(rest[sIdx + 1].text, depth + 1);   // `env -S "bash -s"`
  }
  if (name === "xargs" || name === "parallel") {
    // stdin drives xargs; with `sh -c` (or any shell) among its words each input line runs.
    return rest.some((w) => (w.hasExpansion && w.text === "") || SHELLS.has(basename(w.text)));
  }
  if (WRAPPERS.has(name)) {
    let r = skipFlags(name, rest);
    if (name === "env") { while (r.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(r[0].text) && !r[0].qstart) r = r.slice(1); }
    if (name === "timeout" || name === "chroot" || name === "flock") r = r.slice(1);    // duration / new root / lock file
    if (!r.length) return name === "chroot" || name === "nsenter" || name === "unshare";   // they spawn a shell without a command
    return wordsFeedShell(r, depth + 1);
  }
  if (CONTAINERS.has(name)) {
    // `docker exec -i c sh`, `podman run -i img /bin/bash`: the first shell word, and what
    // follows it, decides; `sh -c '…'` gives stdin to the -c command, not to the shell. An
    // expansion that is a whole word in a place a shell could go fails closed; `-v $PWD:/w` does not.
    for (let k = 0; k < rest.length; k++) {
      if (rest[k].hasExpansion && rest[k].text === "" && !rest[k].quoted) return true;
      if (!rest[k].quoted && SHELLS.has(basename(rest[k].text))) return shellReadsStdin(rest.slice(k + 1));
    }
    return false;
  }
  return false;
}

// The pipeline that holds position `at`, at its own nesting level: { stages, starts, idx, frame }
// where frame = { start, end, kind } is the innermost frame enclosing `at` (or null), so the
// caller can look at what the frame's output feeds.
function pipelineAround(line, at) {
  const open = [];
  let frame = null;
  lex(line, (j, tok, depth, fs) => {
    if (tok === "$(" || tok === "(") open.push({ start: j, kind: tok === "(" ? (line[j] === "{" ? "{" : "(") : "$(", depth, end: -1 });
    else if (tok === ")") { const f = open.find((o) => o.start === fs); if (f) f.end = j; }
  });
  for (const f of open) if (f.start < at && (f.end === -1 || f.end > at)) if (!frame || f.start > frame.start) frame = f;
  const from = frame ? frame.start + (frame.kind === "$(" && line[frame.start] !== "`" ? 2 : 1) : 0;
  const to = frame && frame.end !== -1 ? frame.end : line.length;
  const level = frame ? frame.depth : 0;
  let start = from, end = to, skip = -1;
  const cuts = [];
  lex(line, (j, tok, depth) => {
    if (j < from || j >= to || depth !== level || tok.length !== 1 || j === skip) return;
    const nx = line[j + 1], pv = line[j - 1];
    const isList = (tok === "|" && nx === "|") || (tok === "&" && nx === "&") || tok === ";" || tok === "\n"
      || (tok === "&" && nx !== ">" && nx !== "&" && pv !== ">" && pv !== "<" && pv !== "|");
    if (isList) {
      const w = (tok === ";" || tok === "\n" || (tok === "&" && nx !== "&")) ? 1 : 2;
      if (j < at) { start = j + w; cuts.length = 0; } else if (end === to) end = j;
      if (w === 2) skip = j + 1;
      return;
    }
    if (tok === "|" && pv !== "|" && nx !== "|" && j >= start && j < end) { cuts.push(j); if (nx === "&") skip = j + 1; }
  });
  const stages = [], starts = [];
  let prev = start;
  for (const c of cuts) { if (c < prev) continue; stages.push(line.slice(prev, c)); starts.push(prev); prev = c + (line[c + 1] === "&" ? 2 : 1); }
  stages.push(line.slice(prev, end)); starts.push(prev);
  let idx = 0;
  for (let k = 0; k < stages.length; k++) if (at >= starts[k] && at <= starts[k] + stages[k].length) { idx = k; break; }
  return { stages, starts, idx, frame };
}

// Process substitutions used as OUTPUT (`cat <<EOF > >(bash)`, `tee >(sh) <<EOF`) inside a stage:
// the stage's output flows into the inner command. Returns the inner texts.
function outputSubstitutions(stage) {
  const inner = [];
  const opens = [];
  lex(stage, (j, tok, depth, fs) => {
    if (tok === "$(" && stage[j] === ">") opens.push({ start: j, end: -1 });
    else if (tok === ")") { const o = opens.find((x) => x.start === fs); if (o) o.end = j; }
  });
  for (const o of opens) inner.push(stage.slice(o.start + 2, o.end === -1 ? stage.length : o.end));
  return inner;
}

// Does text produced at position `at` of the line (a heredoc body) reach a shell as commands, and
// which one? null: it does not. "here": the stage that owns it is `.`/`source` reading stdin, alone
// in its pipeline, so the body runs in this very shell and a cd in it stays (see analyzableTexts).
// "frame": it reaches one through the output of the substitution around it (`eval "$(cat <<EOF…)"`),
// whose consumer decides. "shell": a shell of its own (`bash <<EOF`, `cat <<EOF | sh`, `ssh host`).
function heredocFeed(line, at) {
  const { stages, idx, frame } = pipelineAround(line, at);
  for (let k = idx; k < stages.length; k++) {
    const words = tokenize(stages[k]);
    if (wordsFeedShell(words, 0)) return stages.length === 1 && runsHere(words) ? "here" : "shell";
    for (const inner of outputSubstitutions(stages[k])) if (anyFeedsShell(inner, 1)) return "shell";
  }
  return frame && outputFeedsShell(line, frame, 0) ? "frame" : null;
}

// Does this simple command run its script in the shell that reads it, not in a process of its own:
// eval, `.` and source, also behind `command` or `builtin`?
function runsHere(words) {
  let i = 0;
  while (i < words.length && ((RESERVED.has(words[i].text) && !words[i].quoted) || (/^[A-Za-z_][A-Za-z0-9_]*=/.test(words[i].text) && !words[i].qstart))) i++;
  while (i < words.length && !words[i].quoted && (words[i].text === "command" || words[i].text === "builtin")) i++;
  const w = words[i];
  return !!w && !w.hasExpansion && (w.text === "eval" || w.text === "." || w.text === "source");
}

// Does the OUTPUT of a frame reach a shell as commands? For `$(`/backticks the enclosing command
// may consume it as a script (`eval "$(cat <<EOF…)"`, `bash -c "$(…)"`, `bash <(…)`); for a
// `( … )` or `{ … }` group nothing does, but a later stage of the enclosing pipeline still can
// (`{ cat <<EOF; } | sh`). And the frame may itself sit inside another one: recurse.
function outputFeedsShell(line, frame, depth) {
  if (depth > 12) return true;
  const outer = pipelineAround(line, frame.start);
  if (frame.kind === "$(") {
    const head = outer.stages[outer.idx].slice(0, Math.max(0, frame.start - outer.starts[outer.idx]));
    if (consumesScript(tokenize(head))) return true;
  }
  for (let k = outer.idx + 1; k < outer.stages.length; k++) {
    if (wordsFeedShell(tokenize(outer.stages[k]), 0)) return true;
    for (const inner of outputSubstitutions(outer.stages[k])) if (anyFeedsShell(inner, 1)) return true;
  }
  return outer.frame ? outputFeedsShell(line, outer.frame, depth + 1) : false;
}

// `eval "$(…)"`, `. <(…)`, `bash -c "$(…)"`, `bash <(…)`: the substituted text is a script.
function consumesScript(words) {
  let i = 0;
  while (i < words.length && ((RESERVED.has(words[i].text) && !words[i].quoted) || (/^[A-Za-z_][A-Za-z0-9_]*=/.test(words[i].text) && !words[i].qstart))) i++;
  if (i >= words.length) return false;
  let name = basename(words[i].text);
  let rest = words.slice(i + 1);
  if (words[i].hasExpansion && !SHELLS.has(name)) return true;
  if (name === "sudo" || name === "doas" || WRAPPERS.has(name)) { const r = skipFlags(name, rest); if (r.length) { name = basename(r[0].text); rest = r.slice(1); if (r[0].hasExpansion && !SHELLS.has(name)) return true; } }
  return name === "eval" || name === "." || name === "source" || SHELLS.has(name);
}

// Is the quoted word that starts after `head` (the words of its command written before it) a
// script the shell runs, rather than an argument that may be data? It is when it is the -c string
// of a shell (`bash -c '…'`, `sudo -u x sh -lc "…"`, `xargs -I{} sh -c '…'`, `find … -exec sh -c
// '…'`), the first word of eval, the command an ssh destination runs (`ssh host '…'`), or su's or
// runuser's -c. A shell named by an expansion counts as one (`"$SHELL" -c '…'`). It says which:
// "eval" (the script runs in this shell, so a cd in it stays), "shell" (in a process of its own), or
// false.
// Called for every quoted span, so it reads a bounded part of the head and the extractor stays
// linear: the -c and its shell are in the head's last SCRIPT_HEAD characters, and eval, ssh, su and
// the wrappers in front of them are a head no longer than that.
const SCRIPT_HEAD = 1024;
function scriptSpan(head) {
  const short = head.length <= SCRIPT_HEAD;
  const words = tokenize(short ? head : head.slice(-SCRIPT_HEAD));
  if (!words.length) return false;
  let c = words.length - 1;
  if (c > 0 && words[c].text === "--" && !words[c].quoted) c--;                         // bash -c -- '…'
  const last = words[c];
  if (!last.quoted && /^-[A-Za-z]*c[A-Za-z]*$/.test(last.text)) {
    let j = c - 1;
    while (j >= 0) {
      const t = words[j].text;
      if (/^([-+][A-Za-z]+|--[A-Za-z][-A-Za-z]*)$/.test(t)) { j--; continue; }            // -l, +x, --norc
      if (j >= 1 && /^[-+][A-Za-z]*[oO]$/.test(words[j - 1].text)) { j -= 2; continue; }   // -o pipefail
      break;
    }
    const w = j >= 0 ? words[j] : null;
    if (w && (SHELLS.has(basename(w.text)) || (w.hasExpansion && (w.text === "" || basename(w.text).startsWith("$"))))) return "shell";
  }
  if (!short) return false;
  let i = 0;
  while (i < words.length && ((RESERVED.has(words[i].text) && !words[i].quoted) || (/^[A-Za-z_][A-Za-z0-9_]*=/.test(words[i].text) && !words[i].qstart))) i++;
  let rest = words.slice(i);
  for (let d = 0; d < 12 && rest.length; d++) {
    const name = basename(rest[0].text);
    if (name === "eval") return rest.length === 1 && "eval";
    if (name === "ssh") return skipFlags("ssh", rest.slice(1)).length === 1 && "shell";
    if (name === "su" || name === "runuser") return (last.text === "-c" || last.text === "--command") && "shell";
    if (name === "sudo" || name === "doas" || WRAPPERS.has(name)) {
      let r = skipFlags(name, rest.slice(1));
      if (name === "env") { while (r.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(r[0].text) && !r[0].qstart) r = r.slice(1); }
      if (name === "timeout" || name === "chroot" || name === "flock") r = r.slice(1);
      rest = r;
      continue;
    }
    break;
  }
  return false;
}

// Returns the text with every heredoc body removed, plus the bodies that feed a shell, and where
// each operator whose body was removed stands in the text returned (see shellScopes).
function splitHeredocs(src) {
  const opRe = /(?<!<)<<(?!<)-?\s*(["']?)([A-Za-z_][A-Za-z0-9_]*)\1/;
  let out = "";
  const bodies = [];
  const handled = [];   // where, in `out`, each operator whose body was taken out stands
  let rest = src;
  for (;;) {
    const m = opRe.exec(rest);
    if (!m) { out += rest; break; }
    // The LOGICAL opener line: joined across backslash-newline in both directions, because
    // bash joins them before it ever parses — `cat <<EOF \` / `| bash` is one line to bash.
    let lineStart = rest.lastIndexOf("\n", m.index) + 1;
    while (lineStart >= 2 && rest[lineStart - 2] === "\\") lineStart = rest.lastIndexOf("\n", lineStart - 2) + 1;
    let eol = rest.indexOf("\n", m.index + m[0].length);
    while (eol !== -1 && rest[eol - 1] === "\\") eol = rest.indexOf("\n", eol + 1);
    if (eol === -1) { out += rest; break; }
    let line = rest.slice(lineStart, eol).replace(/\\\n/g, " ");
    const at = m.index - lineStart - (rest.slice(lineStart, m.index).match(/\\\n/g) || []).length;
    const opAt = out.length + m.index;   // where the operator stands in `out` (see analyzableTexts)
    handled.push(opAt);
    out += rest.slice(0, eol + 1);
    const tail = rest.slice(eol + 1);
    const endRe = new RegExp("^\\t*" + m[2] + "[ \\t]*\\r?$", "m");
    const em = endRe.exec(tail);
    let forced = false;
    if (em) {
      // The command may continue after the terminator while a frame or quote is still open on
      // the opener line: append those lines (joined) so the pipeline analysis sees the consumer.
      // No fixed cap decides the verdict: past the sanity bound with the command STILL open, the
      // body is treated as shell-fed (closed), never judged on a truncated opener.
      const after = tail.slice(em.index + em[0].length).split("\n");
      let k = 1;
      for (; k < after.length && k <= 2000 && openAtEnd(line); k++) line += " " + after[k];
      if (openAtEnd(line)) forced = true;
    } else if (openAtEnd(line)) {
      forced = true;
    }
    const how = forced ? "shell" : heredocFeed(line, at);
    const shellFed = how !== null;
    if (!em) {
      // Unterminated heredoc: the rest is its body. Dropped (conservative) unless it feeds a
      // shell — then it is code that WILL run, and it is analyzed.
      if (shellFed) bodies.push({ text: tail, at: opAt, how });
      break;
    }
    if (shellFed) bodies.push({ text: tail.slice(0, em.index), at: opAt, how });
    rest = tail.slice(em.index + em[0].length);
  }
  return { out, bodies, handled };
}

// --- Where each segment stands ------------------------------------------------------------------
// The directory a git command runs in is the session's, moved by every cd/pushd/popd before it
// (command_git_dir in the shell). A cd inside a subshell holds only there: in
// `(cd ../other && git pull); git push --force-with-lease` the push runs where the session stands,
// and in `x=$(cd ../other && pwd)` the cd never leaves the substitution. The segments arrive as a
// flat list, so until 2026-10-03 every cd counted for every later command, and a cd in a closed
// subshell moved the push after it, both ways: a lease to develop passed, and one to the agent's own
// branch was denied. Neither the order of the segments nor their text says which subshell a cd was
// in, so each segment is sent with its position, on a line of its own before it (only when it
// changes): "\x01<o> <p>". The segments go out in the order of their positions, so a cd reaches the
// shell before every command it stands in front of (an eval's script is read after the words
// around it, and a heredoc body after the whole text that holds it).
//   - <p>: the scopes around it, outermost first, as "/<id>/<id>/…/": the subshells `( … )`,
//     `$( … )`, backticks, `<( … )` and `>( … )` as the shell reads them (shellScopes); not
//     `{ … }`, which runs in this shell. A script span (`bash -c '…'`, ssh's) and a heredoc body fed
//     to a shell (`bash <<EOF`) run in a process of their own: a scope of their own ("q", "h") inside
//     the ones around them. eval's script and a heredoc read by `.`/`source` run in this shell: no
//     scope of their own, so their cd stays, as it does. A quoted span that may be data
//     (`echo "cd x && git push"`, a --body) is a scope of its own too ("v"): its cd moves what it
//     holds and nothing outside it. So is a comment ("c"), which the shell does not run.
//   - <o>: where it starts, as dot-separated offsets: one per heredoc level (a body's segments
//     come after its operator's position in the text that holds it). The segments of a span or a
//     substitution body share the span's or the body's position, in their own order.
// A cd counts for a git command when its scope encloses the command's (or is the same) and it
// stands before it. A pipeline stage, `&` and a subshell inside a `bash -c` script are not read as
// scopes: a cd there counts as before.
// A text whose scopes cannot be read (nested past SCOPE_DEPTH_MAX) is sent with "\x01! /" in front
// and no other position: the shell then denies a git command whose directory a cd may have moved.

// The scopes of a text, as the shell reads them: { frames: [{ kind, s, e, cmd }], comments: [[a,
// b]] }. A frame is a subshell: kind "(", "$(", "`", "<(" or ">(", s where it opens, e where it closes
// (the text's end when it does not), cmd where the simple command that holds it starts; in the
// order they open (an outer one before the ones inside it). A comment runs from its `#` to the end
// of its line. lex (above) reads `(` and `)` wherever it meets them, which serves the rules it
// feeds, but not this: a comment (`# (`), the `)` that ends a case pattern, `${x:-(}`, `$(( … ))`,
// `(( … ))`, `a=( … )`, `@( … )` and `[[ ( … ) ]]` are not subshells, and read as ones they moved a
// cd in or out of the subshell around it (found 2026-10-03, verifying this change: a lease to
// develop passed). A heredoc whose body is still in the text (splitHeredocs did not take it out: a
// delimiter like 'E-F' or \EOF) is data up to its terminator line: a comment, for this purpose, and
// a `)` in it closes nothing. handled: the positions of the operators whose body splitHeredocs took
// out. Throws past SCOPE_DEPTH_MAX levels of nesting, or past SCOPE_STEPS_MAX steps (see scopesOf).
const SCOPE_DEPTH_MAX = 400;
let SCOPE_STEPS = 0;
let SCOPE_STEPS_MAX = Infinity;
const CMD_KEYWORDS = new Set(["if", "then", "else", "elif", "do", "while", "until", "!", "{", "time", "coproc"]);
function shellScopes(text, depth0 = 0, handled = []) {
  const n = text.length;
  const frames = [];
  const comments = [];
  let depth = depth0;
  let curCmd = 0;
  const done = new Set(handled);
  let pending = [];   // heredocs whose body starts at the next newline: [{ delim, strip }]
  // Where an arithmetic reading (`$((`, `((`) was tried and did not close with `))`: read again from
  // there, it is a subshell at once. Without it each unclosed `$((` inside another was read twice,
  // the inner ones twice per outer reading: 2^n readings for n levels (found 2026-10-03, verifying
  // #299: 34 levels, some 140 bytes, ran past the hook's timeout, and a hook that times out lets
  // the command run).
  const arithFailed = new Set();
  const step = () => { if (++SCOPE_STEPS > SCOPE_STEPS_MAX) throw new Error("scopes too costly to read"); };
  // Past the newline at j: the bodies of the heredocs pending, each up to its terminator line (the
  // delimiter alone on its line, as bash reads it: tabs before it only with <<-), or to the end of
  // the text.
  const nl = (j) => {
    j++;
    for (const h of pending) {
      const from = j;
      const endRe = new RegExp("^" + (h.strip ? "\t*" : "") + h.delim.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "$");
      let found = false;
      while (j < n && !found) {
        step();
        let e = text.indexOf("\n", j);
        if (e === -1) e = n;
        found = endRe.test(text.slice(j, e));
        j = Math.min(n, e + 1);
      }
      comments.push([from, j]);
    }
    pending = [];
    return j;
  };
  const isMeta = (c) => c === undefined || isSpace(c) || c === ";" || c === "&" || c === "|" || c === "(" || c === ")" || c === "<" || c === ">";
  const enter = () => { step(); if (++depth > SCOPE_DEPTH_MAX) throw new Error("scopes nested too deep"); };
  const sq = (i) => { const j = text.indexOf("'", i + 1); return j === -1 ? n : j + 1; };
  const ansi = (i) => {
    let j = i + 2;
    while (j < n && text[j] !== "'") j += text[j] === "\\" ? 2 : 1;
    return Math.min(n, j + 1);
  };
  const comment = (i) => {
    let j = text.indexOf("\n", i);
    if (j === -1) j = n;
    comments.push([i, j]);
    return j;
  };
  // Each reader takes the index of what it reads and returns the index past it.
  function dq(i) {
    enter();
    let j = i + 1;
    while (j < n) {
      step();
      const c = text[j];
      if (c === "\\") { j += 2; continue; }
      if (c === '"') { depth--; return j + 1; }
      if (c === "$") { j = dollar(j, true); continue; }
      if (c === "`") { j = tick(j); continue; }
      j++;
    }
    depth--;
    return n;
  }
  function dollar(i, inDq) {
    const nx = text[i + 1];
    if (nx === "(") {
      if (text[i + 2] === "(" && !arithFailed.has(i + 3)) {
        const mark = [frames.length, comments.length, pending.slice()];
        const a = arith(i + 3);
        if (a !== -1) return a;
        arithFailed.add(i + 3);
        frames.length = mark[0];
        comments.length = mark[1];
        pending = mark[2];
      }
      return sub("$(", i, i + 2);
    }
    if (nx === "{") return param(i + 2, inDq);
    if (!inDq && nx === "'") return ansi(i);
    if (!inDq && nx === '"') return dq(i + 1);
    return i + 1;
  }
  function sub(kind, s, from) {
    const f = { kind, s, e: n, cmd: curCmd };
    frames.push(f);
    const saved = curCmd;
    const j = list(from, ")");
    curCmd = saved;
    f.e = j;
    return j < n ? j + 1 : n;
  }
  // A backtick substitution ends at the first backtick no backslash escapes; what it holds is
  // read on its own.
  function tick(i) {
    let j = i + 1;
    while (j < n && text[j] !== "`") j += text[j] === "\\" ? 2 : 1;
    const e = Math.min(j, n);
    frames.push({ kind: "`", s: i, e, cmd: curCmd });
    const inner = shellScopes(text.slice(i + 1, e), depth + 1, [...done].filter((h) => h > i && h < e).map((h) => h - i - 1));
    for (const g of inner.frames) frames.push({ kind: g.kind, s: g.s + i + 1, e: g.e + i + 1, cmd: g.cmd + i + 1 });
    for (const [a, b] of inner.comments) comments.push([a + i + 1, b + i + 1]);
    return j < n ? j + 1 : n;
  }
  function param(i, inDq) {
    enter();
    let j = i;
    while (j < n) {
      step();
      const c = text[j];
      if (c === "\\") { j += 2; continue; }
      if (c === "}") { depth--; return j + 1; }
      if (c === "$") { j = dollar(j, inDq); continue; }
      if (c === "`") { j = tick(j); continue; }
      if (c === '"') { j = dq(j); continue; }
      if (c === "'" && !inDq) { j = sq(j); continue; }
      j++;
    }
    depth--;
    return n;
  }
  // The inside of `$((` or `((`: past the `))` that closes it, or -1 when a `)` closes it alone
  // (then it was `$( (` or `( (`).
  function arith(i) {
    enter();
    let j = i, d = 0;
    while (j < n) {
      step();
      const c = text[j];
      if (c === "\\") { j += 2; continue; }
      if (c === "(") { d++; j++; continue; }
      if (c === ")") {
        if (d > 0) { d--; j++; continue; }
        depth--;
        return text[j + 1] === ")" ? j + 2 : -1;
      }
      if (c === "$") { j = dollar(j, false); continue; }
      if (c === "`") { j = tick(j); continue; }
      if (c === '"') { j = dq(j); continue; }
      if (c === "'") { j = sq(j); continue; }
      j++;
    }
    depth--;
    return -1;
  }
  // A pattern group `@( … )` and its kin, from its `(`.
  function group(i) {
    enter();
    let j = i + 1, d = 1;
    while (j < n) {
      step();
      const c = text[j];
      if (c === "\\") { j += 2; continue; }
      if (c === "(") { d++; j++; continue; }
      if (c === ")") { if (--d === 0) { depth--; return j + 1; } j++; continue; }
      if (c === "'") { j = sq(j); continue; }
      if (c === '"') { j = dq(j); continue; }
      if (c === "$") { j = dollar(j, false); continue; }
      if (c === "`") { j = tick(j); continue; }
      j++;
    }
    depth--;
    return n;
  }
  // The values of an array assignment `a=( … )`, from its `(`.
  function arrayList(i) {
    enter();
    let j = i + 1;
    while (j < n) {
      step();
      const c = text[j];
      if (c === "\n") { j = nl(j); continue; }
      if (isSpace(c)) { j++; continue; }
      if (c === "\\" && text[j + 1] === "\n") { j += 2; continue; }
      if (c === ")") { depth--; return j + 1; }
      if (c === "#") { j = comment(j); continue; }
      const k = word(j);
      j = k > j ? k : j + 1;
    }
    depth--;
    return n;
  }
  function word(i) {
    let j = i;
    while (j < n) {
      step();
      const c = text[j];
      if (c === "\\") { j += 2; continue; }
      if (isMeta(c)) {
        if (c === "(" && j > i) {
          if ("@!?*+".includes(text[j - 1])) { j = group(j); continue; }
          if (/^[A-Za-z_][A-Za-z0-9_]*(\[[^\]]*\])?\+?=$/.test(text.slice(i, j))) { j = arrayList(j); continue; }
        }
        break;
      }
      if (c === "'") { j = sq(j); continue; }
      if (c === '"') { j = dq(j); continue; }
      if (c === "$") { j = dollar(j, false); continue; }
      if (c === "`") { j = tick(j); continue; }
      j++;
    }
    return Math.min(j, n);
  }
  function blanks(j, newlines) {
    while (j < n) {
      step();
      const c = text[j];
      if (newlines && c === "\n") { j = nl(j); continue; }
      if (c === " " || c === "\t" || c === "\r") { j++; continue; }
      if (c === "\\" && text[j + 1] === "\n") { j += 2; continue; }
      if (newlines && c === "#") { j = comment(j); continue; }
      break;
    }
    return j;
  }
  // `case <word> in <pattern>) <commands> ;; … esac`, from past `case`. A `)` that does not belong
  // to it (a frame around the case closes there) is left for the caller.
  function caseStmt(i) {
    enter();
    let j = blanks(i, true);
    const k = word(j);
    j = blanks(k > j ? k : j + 1, true);
    if (/^in(?=[\s;&|()<>]|$)/.test(text.slice(j, j + 3))) j += 2;
    while (j < n) {
      step();
      j = blanks(j, true);
      if (j >= n) break;
      if (/^esac(?=[\s;&|()<>]|$)/.test(text.slice(j, j + 5))) { depth--; return j + 4; }
      if (text[j] === ")") { depth--; return j; }
      if (text[j] === "(") j++;
      while (j < n) {
        step();
        j = blanks(j, false);
        const c = text[j];
        if (c === ")") { j++; break; }
        if (c === "\n") { j = nl(j); continue; }
        if (c === "|") { j++; continue; }
        const w = word(j);
        j = w > j ? w : j + 1;
      }
      const t = list(j, "case");
      if (t >= n) break;
      if (text[t] === ";") { j = t + (text[t + 1] === ";" && text[t + 2] === "&" ? 3 : 2); continue; }
      depth--;
      return text[t] === ")" ? t : t + 4;
    }
    depth--;
    return n;
  }
  // `[[ … ]]`, from past `[[`: its parentheses group, they are no subshell.
  function dbracket(i) {
    enter();
    let j = i;
    while (j < n) {
      step();
      const c = text[j];
      if (c === "\n") { j = nl(j); continue; }
      if (isSpace(c)) { j++; continue; }
      if (c === "\\" && text[j + 1] === "\n") { j += 2; continue; }
      if (c === "]" && text[j + 1] === "]" && isMeta(text[j + 2])) { depth--; return j + 2; }
      if ("()<>&|!;".includes(c)) { j++; continue; }
      const k = word(j);
      j = k > j ? k : j + 1;
    }
    depth--;
    return n;
  }
  // A list of commands, up to the `)` that closes its frame (end ")"), up to `;;`, `;&`, `;;&` or
  // `esac` (end "case"), or to the end of the text: returns where it stops.
  function list(i, end) {
    enter();
    let j = i, cmdPos = true;
    while (j < n) {
      step();
      const c = text[j];
      if (c === " " || c === "\t" || c === "\r") { j++; continue; }
      if (c === "\\" && text[j + 1] === "\n") { j += 2; continue; }
      if (c === "\n") { j = nl(j); cmdPos = true; continue; }
      if (c === "#") { j = comment(j); continue; }
      if (c === ")") {
        if (end) { depth--; return j; }
        j++;
        continue;
      }
      if (c === ";") {
        if (text[j + 1] === ";" || text[j + 1] === "&") {
          if (end === "case") { depth--; return j; }
          j += text[j + 1] === ";" && text[j + 2] === "&" ? 3 : 2;
        } else j++;
        cmdPos = true;
        continue;
      }
      if (c === "&" || c === "|") {
        if (c === "&" && text[j + 1] === ">") { j = word(blanks(j + (text[j + 2] === ">" ? 3 : 2), false)); continue; }
        j += text[j + 1] === c || (c === "|" && text[j + 1] === "&") ? 2 : 1;
        cmdPos = true;
        continue;
      }
      if (c === "<" || c === ">") {
        if (text[j + 1] === "(") { j = sub(c + "(", j, j + 2); continue; }
        if (c === "<" && text[j + 1] === "<" && text[j + 2] !== "<") {
          // A heredoc: its delimiter, quotes and backslashes taken out; its body comes after the
          // next newline, unless splitHeredocs already took it out.
          const strip = text[j + 2] === "-";
          const k = blanks(j + (strip ? 3 : 2), false);
          const w = word(k);
          if (!done.has(j) && w > k) pending.push({ strip, delim: text.slice(k, w).replace(/\\(.)/g, "$1").replace(/['"]/g, "") });
          j = w;
          continue;
        }
        let k = j + 1;
        while (k < n && "<>&|-".includes(text[k])) k++;
        j = word(blanks(k, false));
        continue;
      }
      if (c === "(") {
        if (cmdPos && text[j + 1] === "(" && !arithFailed.has(j + 2)) {
          const mark = [frames.length, comments.length, pending.slice()];
          const a = arith(j + 2);
          if (a !== -1) { j = a; cmdPos = false; continue; }
          arithFailed.add(j + 2);
          frames.length = mark[0];
          comments.length = mark[1];
          pending = mark[2];
        }
        if (!cmdPos) {
          const k = blanks(j + 1, false);
          if (text[k] === ")") { j = k + 1; cmdPos = true; continue; }   // `name ()`: a function
        }
        curCmd = j;
        j = sub("(", j, j + 1);
        cmdPos = false;
        continue;
      }
      if (cmdPos) curCmd = j;
      const k = word(j);
      if (k === j) { j++; continue; }
      const w = text.slice(j, k);
      j = k;
      if (/^[0-9]+$/.test(w) && (text[k] === "<" || text[k] === ">")) continue;   // 2>&1
      if (cmdPos) {
        if (w === "case") { j = caseStmt(k); cmdPos = false; continue; }
        if (w === "[[") { j = dbracket(k); cmdPos = false; continue; }
        if (end === "case" && w === "esac") { depth--; return k - 4; }
        if (CMD_KEYWORDS.has(w)) continue;
        if (/^[A-Za-z_][A-Za-z0-9_]*(\[[^\]]*\])?\+?=/.test(w)) continue;
      }
      cmdPos = false;
    }
    depth--;
    return n;
  }
  list(0, null);
  return { frames, comments };
}
// shellScopes, or null when the text is nested past what it reads or costs more to read than
// SCOPE_STEPS_MAX steps: 64 per character, where a real command takes fewer than 2 (measured over
// the 86,105 real commands of the 31 days to 2026-10-03: 1.53 at most, on a text of 20 characters or
// more), so a reading that has gone pathological stops in a fraction of a second, and its text is
// unreadable like one nested too deep.
function scopesOf(text, handled = []) {
  SCOPE_STEPS = 0;
  SCOPE_STEPS_MAX = 64 * text.length + 100000;
  try {
    return shellScopes(text, 0, handled);
  } catch (e) {
    return null;
  }
}
// The context { o, p } of position o of a text that stands at base ({ o, p } of the text itself),
// with extra appended to the scopes. sc: the text's shellScopes.
function ctxAt(sc, base, o, extra = "") {
  let p = base.p;
  for (const f of sc.frames) if (f.s < o && o < f.e) p += base.o + f.s + "/";
  for (const [a, b] of sc.comments) if (a <= o && o < b) { p += "c" + base.o + a + "/"; break; }
  return { o: base.o + o, p: p + extra };
}
// The innermost frame of sc around position o, or null.
function frameAround(sc, o) {
  let in_ = null;
  for (const f of sc.frames) if (f.s < o && o < f.e && (!in_ || f.s > in_.s)) in_ = f;
  return in_;
}
let SCOPES_UNREADABLE = false;
const NO_SCOPES = { frames: [], comments: [] };

// Every text the rules must see: the command with heredoc bodies removed, then each body that
// feeds a shell, recursively (depth-capped: a pathological nesting must not hang the hook —
// and past the cap the body is emitted WHOLE rather than dropped, so depth is never a bypass).
// Each one as { text, p, o }: where it stands (see "Where each segment stands" above). A body fed
// to a shell (`bash <<EOF`) runs in it: a scope of its own, inside the frames around its operator.
// One `.`/`source` reads runs in this shell, and so does one whose substitution eval, `.` or source
// reads (`eval "$(cat <<EOF…)"`): in the scope of that command.
function analyzableTexts(src, depth, base = { p: "/", o: "" }) {
  if (depth >= 64) return [{ text: src, p: base.p, o: base.o, handled: [] }];
  const { out, bodies, handled } = splitHeredocs(src);
  const texts = [{ text: out, p: base.p, o: base.o, handled }];
  let sc = NO_SCOPES;
  if (bodies.length) {
    sc = scopesOf(out, handled);
    if (!sc) { SCOPES_UNREADABLE = true; sc = NO_SCOPES; }
  }
  for (const b of bodies) {
    const c = ctxAt(sc, base, b.at);
    let p = c.p + "h" + c.o + "/";
    if (b.how === "here") p = c.p;
    else if (b.how === "frame") {
      const f = frameAround(sc, b.at);
      if (f && f.kind !== "(" && runsHere(tokenize(out.slice(f.cmd, f.s)))) p = ctxAt(sc, base, f.s).p;
    }
    for (const t of analyzableTexts(b.text, depth + 1, { p, o: c.o + "." })) texts.push(t);
  }
  return texts;
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
//
// A substitution still cuts, and that leaves HALF a command on each side of it: in
//   gh pr create --title "t" --body "$(cat b.md)" --label semver:patch
// the words before `$(` are one segment and the rest another, so a rule that needs the WHOLE
// command (is the label there? which PR, in which repository?) reads a half and gets it wrong.
// Measured over the 30 days to 2026-09-30: that shape, label present, was denied for lacking it.
// So at the TOP level, a segment cut at a substitution boundary — before one opens, or after one
// closes — is emitted with a leading TAB (PARTIAL). Every rule still reads it; the few that need
// the whole command skip it and read the masked twin instead (see maskSubstitutions below): the
// same command with the substitution replaced by a placeholder, which the caller always emits
// when there is a substitution. A quoted span re-split below has no masked twin of its own, so
// its segments are never marked PARTIAL and every rule reads them as before.
//
// They carry another mark instead, a leading vertical tab (QUOTED in check_segment): the text of a
// quoted span may be a command (`bash -c "…"`) or data (`grep -E 'pr-merge\.sh merge|x'`), and the
// guard cannot tell which. Every rule reads it as before. What reads the command word the way the
// shell does (see cw_read) reads only the segments that are certainly commands.
//
// The twin masks only the OUTERMOST substitutions (`spans`, from substSpans), so a half that lies
// INSIDE one is not in the twin at all: in
//   out=$(gh pr merge 456 --squash --subject "$(git log -1 --format=%s)")
// the twin is `out=$__GUARD_SUBST__`, and skipping the half `gh pr merge 456 --squash --subject "`
// left that merge judged by nobody (found 2026-09-30, verifying this change: a PR whose base is
// the protected branch merged by the agent). So a half is marked only when no substitution span
// overlaps it; one inside a substitution is read by every rule, as before this mark existed.
function splitSegments(str, top = true, spans = [], code = top, info = null) {
  const out = [];
  const inner = [];
  let qAt = 0;      // where the current quoted span opens in str
  let cur = "";
  let buf = "";     // text inside the current quoted span
  let q = null;     // null | "'" | '"'
  let qHead = "";   // the segment as it stood when the current quoted span opened
  let cutLeft = false;   // this segment starts right after a substitution closed
  const frames = [];     // unquoted "$(" and "(" still open, to tell which one a ")" closes
  let tick = false;      // inside a backtick substitution
  let i = 0;             // the scan position (hoisted: push reads it)
  let from = 0;          // where the current segment starts in str
  const insideSubst = (a, b) => spans.some(([s, e]) => a < e && s < b);
  const push = (cutRight = false) => {
    const t = cur.trim();
    if (t) {
      out.push(top && (cutLeft || cutRight) && !insideSubst(from, i) ? "\t" + t : t);
      if (info) info.push({ at: from, kind: null });
    }
    cur = "";
    cutLeft = false;
    from = i + 1;
  };
  const openSubst = () => { push(true); };
  const closeSubst = () => { push(); cutLeft = true; };
  const backtick = () => { tick = !tick; if (tick) openSubst(); else closeSubst(); };
  const closeQuote = () => {
    const t = buf.trim();
    if (t) inner.push({ t, qc: q, script: code && scriptSpan(qHead), at: qAt });
    buf = "";
    q = null;
  };
  for (; i < str.length; i++) {
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
      if (c === "$" && next === "(") { openSubst(); i++; continue; }
      if (c === "`") { backtick(); continue; }
      cur += c; buf += c;
      continue;
    }
    // A backslash-newline is a line continuation, not two characters: bash joins the lines
    // before parsing. Keeping the pair verbatim carries a raw newline into the line-based read
    // loop below and TEARS THE SEGMENT IN HALF, and half a command satisfies no rule honestly:
    // one that requires a flag to be present stops seeing it, one that forbids a shape stops
    // recognising it. Joining first is what lets every rule read the whole command.
    if (c === "\\" && next === "\n") { cur += " "; i++; continue; }
    if (c === "\\" && next) { cur += c + next; i++; continue; }
    if (c === "'" || c === '"') { q = c; qHead = cur; qAt = i; cur += c; buf = ""; continue; }
    if (c === "$" && next === "(") { frames.push("$"); openSubst(); i++; continue; }
    if (c === "`") { backtick(); continue; }
    if (c === "|" || c === "&") {
      if (next === c) i++; // || and && are one operator, not two
      push();
      continue;
    }
    if (c === "(") { frames.push("("); push(); continue; }
    if (c === ")") { if (frames.pop() === "$") closeSubst(); else push(); continue; }
    if (c === ";" || c === "\n") { push(); continue; }
    cur += c;
  }
  push();
  // An unterminated quote leaves text in buf; analyze it rather than drop it.
  if (buf.trim()) inner.push({ t: buf.trim(), qc: q, script: code && scriptSpan(qHead), at: qAt });
  // The quoted spans are re-split with the same rules, so an operator inside a quoted
  // command still separates the commands it joins.
  // A span that is certainly a script (scriptSpan: `bash -c '…'`, `eval "…"`, `ssh host '…'`) of a
  // text that is certainly a command is re-split as the shell will read it, unmarked: its own
  // quoting level taken off (inside "…", \" \\ \$ and \` are the characters themselves), so the
  // command word in it is read the way the shell reads it (see cw_read), and so are the bodies of
  // its substitutions. Every rule reads those segments as it read the marked ones, so the marked
  // reading is kept only when it is a different text (a "…" span with escapes in it).
  for (const { t, qc, script, at } of inner) {
    if (t === str.trim()) continue; // no progress: would recurse forever
    const u = script && qc === '"' ? t.replace(/\\([\\"$`])/g, "$1") : t;
    const asCode = script && u !== str.trim();
    if (!asCode || u !== t) {
      for (const s of splitSegments(t, false)) {
        out.push(s[0] === "\v" ? s : "\v" + s);
        if (info) info.push({ at, kind: "quoted" });
      }
    }
    if (asCode) {
      const mine = splitSegments(u, false, [], true);
      addBodies(mine, u);
      for (const s of mine) {
        out.push(s);
        if (info) info.push({ at, kind: s[0] === "\v" ? script + "-quoted" : script });
      }
    }
  }
  return out;
}

// The body of every command substitution lex sees in a text that is a command (`$(…)`, backticks,
// `<(…)`, `>(…)`), and the bodies inside those, in order. A body is a command wherever it stands:
// in `x="$(cd d && git push --force)"` splitSegments meets it inside a double-quoted span, which
// may be data (\v), and the command word the shell reads there went unread (found 2026-10-02,
// verifying this change). So each body is ALSO split on its own as a command, unmarked.
// addBodies <segments of text> <text>: the segments of text's substitution bodies added to them;
// one that is already there marked as a quoted span (\v) takes its place, since every rule reads it
// as before and the command word is read too; one already there unmarked is not added again. Only
// the commands of a body: a quoted span inside it (a jq filter, a node -e program) was already read
// as one with the text around it, and read again on its own it is data judged as commands (three
// real commands of the 31 days to 2026-10-02 were denied that way while this was written).
// With ctxs (one per segment) and ctxOf (a body's offset in text -> its context), a body segment
// gets the context of its body, which runs in a subshell (see "Where each segment stands").
function addBodies(segs, text, ctxs = null, ctxOf = null) {
  const at = new Map();
  segs.forEach((s, k) => { if (!at.has(s)) at.set(s, k); });
  for (const { body, off } of substBodies(text, 0, [], 0)) {
    const c = ctxOf ? ctxOf(off) : null;
    for (const s of splitSegments(body, false, [], true)) {
      if (s[0] === "\v" || at.has(s)) continue;
      const k = at.get("\v" + s);
      if (k !== undefined) {
        segs[k] = s;
        if (ctxs) ctxs[k] = c;
        at.delete("\v" + s);
        at.set(s, k);
      } else {
        at.set(s, segs.length);
        segs.push(s);
        if (ctxs) ctxs.push(c);
      }
    }
  }
}
function substBodies(text, depth, acc, base = 0) {
  if (depth > 16) return acc;
  for (const [a, b] of substSpans(text)) {
    const open = text[a] === "`" ? 1 : 2;
    const close = b - a > open && text[b - 1] === (open === 1 ? "`" : ")") ? 1 : 0;
    const body = text.slice(a + open, b - close);
    if (!body.trim()) continue;
    acc.push({ body, off: base + a + open });
    substBodies(body, depth + 1, acc, base + a + open);
  }
  return acc;
}

// A command whose argument holds a command or process substitution is still ONE command, but
// splitSegments cuts it at the substitution: the words before it and the words after it arrive
// as separate segments, and a rule that needs both halves (a destination and the flags around
// it) reads neither. So each text is ALSO split with every outermost substitution — `$(…)`,
// backticks, `<(…)`, `>(…)` — replaced by one placeholder word that carries a `$`: the command
// around it is read whole, and a rule that asks "is this word literal?" gets a truthful no.
// Coverage is additive, the same contract as the quoted spans above: the original segments,
// the substitution bodies included, are still emitted; the masked ones are extra.
const SUBST_PLACEHOLDER = "$__GUARD_SUBST__";
// The outermost substitutions of a text as [start, end) spans, as lex sees them. One reader serves
// the twin (maskSubstitutions) and the PARTIAL marks (splitSegments), so the two cannot disagree on
// where a substitution is.
function substSpans(text) {
  const starts = new Set();
  const spans = [];
  let open = 0, from = -1;
  lex(text, (j, tok, depth, frameStart) => {
    if (tok === "$(") { starts.add(j); if (open === 0) from = j; open++; return; }
    if (tok === ")" && starts.has(frameStart)) { open--; if (open === 0) spans.push([from, j + 1]); }
  });
  if (open > 0 && from >= 0) spans.push([from, text.length]); // unterminated: masked to the end
  return spans;
}
function maskSubstitutions(text, spans = substSpans(text)) {
  if (!spans.length) return text;
  let out = "", k = 0;
  for (const [a, b] of spans) { out += text.slice(k, a) + SUBST_PLACEHOLDER; k = b; }
  return out + text.slice(k);
}

// Every segment of every text with where it stands, sent in the order of their positions.
const all = [];
for (const tx of analyzableTexts(cmd, 0)) {
  const text = tx.text;
  const spans = substSpans(text);
  let sc = scopesOf(text, tx.handled);
  if (!sc) { SCOPES_UNREADABLE = true; sc = NO_SCOPES; }
  // The context of a position of text, for a segment of that kind (see splitSegments): a script a
  // shell of its own runs (`bash -c '…'`) is a scope of its own, and so is a quoted span that may be
  // data, inside the script or not.
  const ctxOf = (o, kind = null) => {
    let extra = "";
    if (kind === "shell" || kind === "shell-quoted") extra += "q" + tx.o + o + "/";
    if (kind === "quoted" || kind === "shell-quoted" || kind === "eval-quoted") extra += "v" + tx.o + o + "/";
    return ctxAt(sc, tx, o, extra);
  };
  const info = [];
  let segs = splitSegments(text, true, spans, true, info);
  const ctxs = info.map((e) => ctxOf(e.at, e.kind));
  const masked = maskSubstitutions(text, spans);
  const tinfo = [];
  let twin = masked !== text ? splitSegments(masked, true, [], true, tinfo) : [];
  // The twin's positions are the masked text's: each one is read back as the original's.
  const unmask = (m) => {
    let shift = 0;
    for (const [a, b] of spans) {
      const ma = a - shift;
      if (m < ma) break;
      if (m < ma + SUBST_PLACEHOLDER.length) return a;
      shift += b - a - SUBST_PLACEHOLDER.length;
    }
    return m + shift;
  };
  const tctxs = tinfo.map((e) => ctxOf(unmask(e.at), e.kind));
  // A half may be skipped only if the twin reads every command WHOLE. No twin (nothing to mask)
  // cannot; nor can a twin that is itself cut at a substitution lex did not see as one (an
  // unquoted `${X:-$(…)}`, which lex skips): its half of the command would be skipped twice and
  // judged never. Then nothing is a half, and every rule reads every segment, as before.
  if (!twin.length || twin.some((s) => s[0] === "\t")) {
    segs = segs.map((s) => s.replace(/^\t/, ""));
    twin = twin.map((s) => s.replace(/^\t/, ""));
  }
  const have = new Set(segs);
  twin.forEach((s, k) => {
    if (have.has(s)) return;
    have.add(s);
    segs.push(s);
    ctxs.push(tctxs[k]);
  });
  addBodies(segs, text, ctxs, (o) => ctxOf(o));
  segs.forEach((seg, k) => all.push({ seg, ctx: ctxs[k] || { o: tx.o + "0", p: tx.p } }));
}
// In the order of their positions (stable: the segments of one position keep theirs), unless a
// text's scopes could not be read: then in the order they were made, behind "\x01! /".
const posCmp = (a, b) => {
  const x = a.split("."), y = b.split(".");
  for (let k = 0; k < x.length && k < y.length; k++) if (Number(x[k]) !== Number(y[k])) return Number(x[k]) - Number(y[k]);
  return x.length - y.length;
};
if (SCOPES_UNREADABLE) process.stdout.write("\x01! /\n");
else all.sort((a, b) => posCmp(a.ctx.o, b.ctx.o));
let lastCtx = "";
for (const { seg, ctx } of all) {
  // Where the segment stands, on a line of its own when it changes (see SEG_POS in the shell).
  const c = "\x01" + ctx.o + " " + ctx.p;
  if (!SCOPES_UNREADABLE && c !== lastCtx) {
    process.stdout.write(c + "\n");
    lastCtx = c;
  }
  // One segment, one line. The shell reads this back with `while read -r`, so a segment
  // carrying a literal newline (only possible from inside a quoted span) would arrive as two
  // segments and each half would be matched on its own. Collapsing to a space keeps the
  // segment whole; the quoted span is still re-split on its own by the `inner` pass above, so
  // nothing that used to be caught stops being caught.
  // A segment of the command that starts with the position mark is sent behind a blank: only
  // the extractor writes position lines (and only the shell's main loop reads them).
  process.stdout.write((seg[0] === "\x01" ? " " + seg : seg).replace(/\n/g, " ") + "\n");
}
JS
# Past 64 KiB bash writes a heredoc to a temporary file before reading it. Where it cannot (a full
# /tmp), the read above fails, and the guard would read no command and let every one run: it reads
# its extractor from this file instead.
if [ -z "${EXTRACT_JS:-}" ] && [ -r "${BASH_SOURCE[0]}" ]; then
  EXTRACT_JS="$(awk '/^JS$/ && f { exit } f { print } /^read -r -d .. EXTRACT_JS <<.JS. / { f = 1 }' \
    "${BASH_SOURCE[0]}" 2>/dev/null || true)"
fi

# --- Paths no session may touch (policy: forbidden_paths) ----------------------
# Each entry of `forbidden_paths` (`~/<dir>` or an absolute path) is out of every session of this
# repository: a Bash, Monitor or PowerShell command that names a path under it — in any of its spellings: `~`, `$HOME`,
# `${HOME}` or the absolute home, with a path boundary on both sides, anywhere in the command text
# (heredoc bodies included) — and a session whose working directory is under it are denied. The
# same script judges the file tools when the repository wires it for them as well
# (`Read|Edit|Write|MultiEdit|NotebookEdit|Grep|Glob`): their path, resolved from the session's
# directory with symlinks followed, and a Glob pattern rooted in it. Empty (the default): no rule.
# Prints "<what touched it>\t<the entry>" for the first hit, nothing otherwise. TEST-ONLY override:
# BASH_GUARD_HOME (the home `~` stands for).
read -r -d '' FORBID_JS <<'JS' || true
const fs = require("fs");
const path = require("path");
let d;
try { d = JSON.parse(fs.readFileSync(0, "utf8")); } catch (e) { process.exit(0); }
if (!d || typeof d !== "object") process.exit(0);
const home = process.argv[1] || "";
const entries = process.argv.slice(2);
const tool = typeof d.tool_name === "string" ? d.tool_name : "";
const input = d.tool_input && typeof d.tool_input === "object" ? d.tool_input : {};
const cwd = typeof d.cwd === "string" && d.cwd ? d.cwd : process.cwd();
function expand(p) {
  if (!home) return p.startsWith("~") || p.startsWith("$HOME") || p.startsWith("${HOME}") ? null : p;
  if (p === "~" || p === "$HOME" || p === "${HOME}") return home;
  for (const pre of ["~/", "$HOME/", "${HOME}/"]) if (p.startsWith(pre)) return path.join(home, p.slice(pre.length));
  return p;
}
// Absolute and normalised, with the symlinks of its longest existing ancestor resolved.
// `..` after a link goes up from where the link points, as the kernel does (`link/../x`): each prefix
// is resolved before its `..` applies.
function real(p, depth = 0) {
  const s = path.isAbsolute(p) ? p : cwd + "/" + p;
  if (!/(^|\/)\.\.(\/|$)/.test(s)) return realPath(s, depth);
  let cur = "/";
  for (const c of s.split("/")) {
    if (!c || c === ".") continue;
    cur = c === ".." ? path.dirname(realPath(cur, depth)) : path.join(cur, c);
  }
  return realPath(cur, depth);
}
function realPath(p, depth) {
  let abs = path.resolve(cwd, p);
  const rest = [];
  for (;;) {
    try { return path.join(fs.realpathSync.native(abs), ...rest); } catch (e) {}
    // A link whose target does not exist (yet) still points there: follow it (#311).
    try {
      if (depth < 8 && fs.lstatSync(abs).isSymbolicLink()) return path.join(real(path.resolve(path.dirname(abs), fs.readlinkSync(abs)), depth + 1), ...rest);
    } catch (e) {}
    const parent = path.dirname(abs);
    if (parent === abs) return path.resolve(cwd, p);
    rest.unshift(path.basename(abs));
    abs = parent;
  }
}
const homeReal = home ? real(home) : "";
const roots = [];
for (const e of entries) {
  const x = expand(e);
  if (!x || !path.isAbsolute(x)) continue;
  const r = real(x);
  if (r === "/" || (homeReal && r === homeReal)) continue;
  roots.push({ entry: e, abs: path.resolve(x), real: r });
}
if (!roots.length) process.exit(0);
const under = (p, root) => p === root || p.startsWith(root.endsWith("/") ? root : root + "/");
// Both readings of `..` count: the kernel's, from where a link points (real), and the text's, which
// Claude Code's file tools apply before opening (`link/../link/x` is `link/x`; independent review of
// #311, which found the file tools reading through it).
function hit(p) {
  if (typeof p !== "string" || !p) return null;
  const x = expand(p);
  if (x === null) return null;
  const r = real(x), l = realPath(path.resolve(cwd, x), 0);
  return roots.find((o) => under(r, o.real) || under(l, o.real) || under(path.resolve(cwd, x), o.abs)) || null;
}
// A directory that holds a root: a recursive read from it, or a pattern that may expand into it,
// reaches the root (found 2026-10-04: a search over the whole home listed the names under one, #311).
function holder(p) {
  if (typeof p !== "string" || !p) return null;
  const x = expand(p);
  if (x === null) return null;
  const r = real(x), l = realPath(path.resolve(cwd, x), 0);
  const a = path.resolve(cwd, x);
  return roots.find((o) => under(o.real, r) || under(o.real, l) || under(o.abs, a)) || null;
}
// One path component of a pattern (`*`, `?`, `[…]`, `{a,b}`) against a name. A pattern the guard
// cannot turn into a regex is compared as written, as bash leaves a pattern that matches nothing.
function compMatch(g, name) {
  if (!/[*?[{]/.test(g)) return g === name;
  let re = "", depth = 0;
  for (let i = 0; i < g.length; i++) {
    const c = g[i];
    if (c === "*") re += "[^/]*";
    else if (c === "?") re += "[^/]";
    else if (c === "[") {
      const j = g.indexOf("]", i + 2);
      if (j < 0) { re += "\\["; continue; }
      re += "[" + g.slice(i + 1, j).replace(/^!/, "^").replace(/\\/g, "\\\\") + "]";
      i = j;
    } else if (c === "{") { re += "(?:"; depth++; }
    else if (c === "}" && depth) { re += ")"; depth--; }
    else if (c === "," && depth) re += "|";
    else re += c.replace(/[.+^$()|\\\]{}]/g, "\\$&");
  }
  try { return new RegExp("^" + re + ")".repeat(depth) + "$").test(name); } catch (e) { return g === name; }
}
// Can an absolute pattern reach a root? Its components match the root's, one by one (`**` matches
// any depth). One that goes on below the root names what is in it. One that stops at the root names
// the directory itself: that reads what is in it only for a command that lists (`ls ~/*`) or a
// recursive read. One that stops above the root names a directory that holds it: only a recursive
// read reaches it.
function globReaches(g, root, rec, lists) {
  const pc = g.split("/"), rc = root.split("/");
  for (let i = 0; i < Math.min(pc.length, rc.length); i++) {
    if (pc[i] === "**") return true;
    if (!compMatch(pc[i], rc[i])) return false;
  }
  if (pc.length > rc.length) return true;
  return pc.length === rc.length ? rec || lists : rec;
}
function globHit(g, rec, lists = rec) {
  return roots.find((o) => globReaches(g, o.abs, rec, lists) || globReaches(g, o.real, rec, lists)) || null;
}
// An ignore glob that leaves out every directory with the root's name: `dir`, `dir/`, `**/dir/**`
// (or a pattern that matches the name). One with a path in it (`x/dir`) leaves out another place.
function dirGlob(v, b) {
  if (typeof v !== "string") return false;
  const x = v.replace(/^(\*\*\/)+/, "").replace(/(\/\*{1,3})+$/, "").replace(/\/+$/, "");
  return x !== "" && !x.includes("/") && compMatch(x, b);
}
function report(what, root) { process.stdout.write(what.replace(/[\t\n\r]/g, " ") + "\t" + root.entry); process.exit(0); }
let h = hit(cwd);
if (h) report("a session whose working directory is " + cwd, h);
if (["Read", "Edit", "Write", "MultiEdit", "NotebookEdit"].includes(tool)) {
  for (const k of ["file_path", "notebook_path"]) { h = hit(input[k]); if (h) report(tool + " on " + input[k], h); }
  process.exit(0);
}
if (tool === "Grep" || tool === "Glob") {
  h = hit(input.path);
  if (h) report(tool + " in " + input.path, h);
  const base = typeof input.path === "string" && input.path ? input.path : cwd;
  const g = typeof input.pattern === "string" ? input.pattern : "";
  if (tool === "Glob" && /^(\/|~|\$HOME|\$\{HOME\})/.test(g)) {
    const fixed = g.split(/[*?[{]/)[0];
    h = hit(fixed || "/");
    if (h) report("Glob " + g, h);
  }
  // Both search every directory under where they start: from one that holds a root, they reach it.
  // Grep from its path (or the session's directory); Glob from the fixed directory of its pattern.
  // A Grep whose glob leaves the root out (`!dir/**`) does not reach it.
  if (tool === "Grep") {
    h = holder(base);
    const gl = typeof input.glob === "string" ? input.glob : "";
    if (h && !(gl.startsWith("!") && dirGlob(gl.slice(1), path.basename(h.abs)))) report("Grep over " + base + ", which holds", h);
  } else {
    const ex = expand(/^(\/|~|\$HOME|\$\{HOME\})/.test(g) ? g : base + "/" + g);
    h = ex === null ? null : globHit(path.resolve(cwd, ex), false);
    // Its fixed directory through a link (`casa/**` with casa -> ~): the pattern runs where it points.
    if (!h && ex !== null) {
      const abs = path.resolve(cwd, ex), fixed = abs.split(/[*?[{]/)[0], dir = fixed.endsWith("/") ? fixed : path.dirname(fixed) + "/";
      const r = realPath(dir, 0);
      if (r !== path.resolve(dir)) h = globHit(path.join(r, abs.slice(dir.length)), false);
    }
    if (h) report("Glob " + g + (input.path ? " in " + input.path : "") + ", which reaches", h);
  }
  process.exit(0);
}
const cmd = typeof input.command === "string" ? input.command : "";
// Monitor and PowerShell run a command too, judged as Bash's (#311).
if (!["Bash", "Monitor", "PowerShell"].includes(tool) || !cmd) process.exit(0);
const esc = (t) => t.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
const homes = [...new Set([home, homeReal].filter(Boolean))];
for (const o of roots) {
  const spell = new Set();
  for (const p of new Set([o.abs, o.real])) {
    spell.add(esc(p));
    for (const hh of homes) {
      if (p.startsWith(hh + "/")) {
        const rel = esc(p.slice(hh.length + 1));
        for (const pre of ["~", "\\$HOME", "\\$\\{HOME\\}", ...homes.map(esc)]) spell.add(pre + "/" + rel);
      }
    }
  }
  const re = new RegExp("(^|[^A-Za-z0-9_./-])(?:" + [...spell].join("|") + ")(?=/|$|[^A-Za-z0-9_.-])", "m");
  // As written, and as the shell reads it once quotes and backslashes are gone (~/"dir", \~/dir).
  if (re.test(cmd) || re.test(cmd.replace(/["'\\]/g, ""))) report("the command", o);
}
// The command's words, as the shell reads them closely enough to see where they point: each path is
// resolved (`~//dir`, `~/./dir`, `../../dir`, `${HOME%/}/dir`, `/proc/self/root/…`), from the directory
// the command's own `cd`s leave it in. A word under a root is denied, and so is a recursive read
// (find, grep -r, tar, rsync…) from a directory that holds one, or a pattern whose fixed part holds
// one (`~/*`, `~/{dir,x}`): bash expands it into the root (#311).
// The index of the `)` that closes the `$(` at i, past quotes and escapes inside it (-1: none).
function closeSub(text, i) {
  let depth = 0;
  for (let j = i + 1; j < text.length; j++) {
    const c = text[j];
    if (c === "\\") { j++; continue; }
    if (c === "'") { j = text.indexOf("'", j + 1); if (j < 0) return -1; continue; }
    if (c === '"') { j++; while (j < text.length && text[j] !== '"') j += text[j] === "\\" ? 2 : 1; continue; }
    if (c === "(") depth++;
    else if (c === ")" && --depth === 0) return j;
  }
  return -1;
}
// A heredoc's body is not commands: it stays on its segment (seg.docs), read only where a shell runs it.
// The same text is read once: the judging of a substitution reads its text again at every level of
// nesting, and the time grew by about 1.8 for each one (independent review of #311).
const wordsMemo = new Map();
function words(text) {
  let r = wordsMemo.get(text);
  if (!r) { r = wordsRaw(text); wordsMemo.set(text, r); }
  return r;
}
function wordsRaw(text) {
  const segs = [];
  let seg = [], w = "", inw = false, q = "", docs = [], pd = 0;
  const arith = [], nested = [];
  const end = () => { if (inw) seg.push(w); w = ""; inw = false; };
  const cut = () => { end(); if (seg.length) segs.push(seg); seg = []; };
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (q === "'") { if (c === "'") q = ""; else w += c; continue; }
    if (q === "$'") { if (c === "'") q = ""; else if (c === "\\" && i + 1 < text.length) w += text[++i]; else w += c; continue; }
    if (q === '"') {
      if (c === '"') q = "";
      else if (c === "\\" && i + 1 < text.length) w += text[++i];
      // A substitution inside double quotes still runs (`"$(find .)"`): its text is read after.
      else if ((c === "$" && text[i + 1] === "(" && text[i + 2] !== "(") || c === "`") {
        let j = i + 1;
        if (c === "`") { while (j < text.length && text[j] !== "`") j += text[j] === "\\" ? 2 : 1; }
        else { j = closeSub(text, i); if (j < 0) j = text.length; }
        nested.push(text.slice(c === "`" ? i + 1 : i + 2, j));
        w += text.slice(i, j + 1);
        i = j;
      } else w += c;
      continue;
    }
    if (c === "$" && (text[i + 1] === "'" || text[i + 1] === '"')) { q = text[i + 1] === "'" ? "$'" : '"'; inw = true; i++; continue; }
    if (c === "'" || c === '"') { q = c; inw = true; continue; }
    // A comment runs to the end of its line; an apostrophe in it opens nothing.
    if (c === "#" && !inw) { while (i + 1 < text.length && text[i + 1] !== "\n") i++; continue; }
    // Inside arithmetic (`$((1<<2))`, `(( y = 1 << 2 ))`) `<<` is a shift, not a heredoc. What is in
    // it is still read: `$(( $(cmd) ))` runs cmd, and `((cmd) )` is a subshell.
    if (c === "(") {
      if (text[i + 1] === "(") arith.push(pd);
      pd++;
    } else if (c === ")") {
      pd--;
      while (arith.length && pd <= arith[arith.length - 1]) arith.pop();
    }
    // A here-string (`<<<word`) is a redirection; its word is a word of its own.
    if (c === "<" && text[i + 1] === "<" && text[i + 2] === "<") { end(); i += 2; continue; }
    if (c === "<" && text[i + 1] === "<" && !arith.length) {
      end();
      i += 2;
      const dash = text[i] === "-";
      if (dash) i++;
      while (text[i] === " " || text[i] === "\t") i++;
      let d = "";
      for (; i < text.length && !" \t\n;&|()<>".includes(text[i]); i++) if (!"'\"\\".includes(text[i])) d += text[i];
      i--;
      if (d) docs.push({ d, dash, seg });
      continue;
    }
    // A redirection glued to a word (`~>/dev/null`) ends it; its target is a word of its own.
    if ((c === "<" || c === ">") && text[i + 1] !== "(") { end(); continue; }
    if (c === "\\" && i + 1 < text.length) { w += text[++i]; inw = true; continue; }
    // An unquoted substitution is part of its word, as the shell has it (`grep -r x $(true) ~` is
    // one grep, found in the independent review of #311); its text is read after as commands. One
    // that does not close is read as it comes.
    // A process substitution (`<(cmd)`, `>(cmd)`) too.
    if ((c === "$" && text[i + 1] === "(" && text[i + 2] !== "(") || c === "`" || ((c === "<" || c === ">") && text[i + 1] === "(")) {
      let j = i + 1;
      if (c === "`") { while (j < text.length && text[j] !== "`") j += text[j] === "\\" ? 2 : 1; }
      else j = closeSub(text, i);
      if (j >= 0 && j < text.length) {
        nested.push(text.slice(c === "`" ? i + 1 : i + 2, j));
        w += text.slice(i, j + 1);
        inw = true;
        i = j;
        continue;
      }
    }
    if (c === "$" && text[i + 1] === "(") {
      if (text[i + 2] === "(") arith.push(pd);
      pd++;
      cut(); i++; continue;
    }
    // The bodies of the line's heredocs. One whose end is not found is read as commands: what the
    // guard took for a heredoc may not be one.
    if (c === "\n" && docs.length) {
      cut();
      const start = i;
      let whole = true;
      for (const doc of docs) {
        const body = [];
        let found = false;
        while (i < text.length) {
          let j = text.indexOf("\n", i + 1);
          if (j < 0) j = text.length;
          const line = text.slice(i + 1, j);
          i = j;
          if ((doc.dash ? line.replace(/^\t+/, "") : line) === doc.d) { found = true; break; }
          body.push(line);
        }
        if (!found) { whole = false; break; }
        (doc.seg.docs = doc.seg.docs || []).push(body.join("\n"));
      }
      if (!whole) i = start;
      docs = [];
      continue;
    }
    // A segment whose output a pipe carries to the next one is marked (seg.pipe).
    if (c === "|" && text[i + 1] !== "|" && text[i - 1] !== "|") { end(); seg.pipe = true; }
    if (";&|()`\n".includes(c)) { cut(); continue; }
    if (c === " " || c === "\t") { end(); continue; }
    w += c; inw = true;
  }
  cut();
  for (const t of nested) segs.push(...words(t));
  return segs;
}
function shellPath(w) {
  let x = w.replace(/^\$\{HOME[^}]*\}/, "$HOME").replace(/^"?\$HOME"?/, "$HOME");
  x = x.replace(/^\/proc\/(self|thread-self|[0-9]+)\/root(?=\/|$)/, "") || "/";
  return x;
}
const WRAP = new Set(["sudo", "doas", "env", "time", "nice", "nohup", "ionice", "timeout", "stdbuf", "command", "exec", "builtin", "xargs", "setsid", "chroot", "busybox", "flock", "runuser"]);
// The options of a wrapper that take a value as the next word (`sudo -u root`, `timeout -s KILL`).
const VALUED = {
  sudo: /^-[ugCDhprtU]$/, doas: /^-[uC]$/, env: /^-[uC]$/, timeout: /^-[sk]$/, nice: /^-n$/,
  ionice: /^-[cnp]$/, stdbuf: /^-[ioe]$/, xargs: /^-[ILnPsdEa]$/, runuser: /^-[ugGl]$/, flock: /^-[wEn]$/,
  chroot: /^--(userspec|groups)$/,
};
const KEYWORDS = new Set(["{", "}", "!", "if", "then", "else", "elif", "fi", "do", "done", "while", "until"]);
const SHELLS = new Set(["bash", "sh", "dash", "zsh", "ksh", "mksh", "ash"]);
// Commands that run a string as a command: a shell's, su's, runuser's and script's `-c`.
const RUNS_C = new Set([...SHELLS, "su", "runuser", "script"]);
const ALWAYS = new Set(["find", "fd", "fdfind", "tree", "du", "ncdu", "rsync", "tar", "bsdtar", "rg", "ag", "ack", "zip", "7z", "rclone", "rgrep", "mv"]);
let rest0 = [];
function recursive(name, flags) {
  if (ALWAYS.has(name)) return true;
  const has = (re) => flags.some((f) => re.test(f));
  switch (name) {
    case "grep": case "egrep": case "fgrep": case "zgrep": case "ugrep": case "ug":
      return has(/^-[A-Za-z]*[rR]/) || has(/^--(dereference-)?recursive$/) || has(/^(--directories=|-d)recurse$/) ||
        rest0.some((f, j) => (f === "-d" || f === "--directories") && rest0[j + 1] === "recurse");
    case "rm": return has(/^-[A-Za-z]*[rR]/) || has(/^--recursive$/);
    case "git": return rest0.includes("grep") && rest0.includes("--no-index");
    case "ls": case "dir": return has(/^-[A-Za-z]*R/) || has(/^--recursive$/);
    case "cp": case "scp": case "mv": return has(/^-[A-Za-z]*[rRa]/) || has(/^--(recursive|archive)$/);
    case "chmod": case "chown": case "chgrp": case "setfacl": case "getfacl": return has(/^-[A-Za-z]*R/) || has(/^--recursive$/);
    default: return false;
  }
}
// `ls -d` names the directories, not what is in them; in a bundle, a letter that takes a value
// (`-I`, `-w`, `-T`) ends it (`-Id` ignores `d`).
function lsDir(flags) {
  for (const f of flags) {
    if (f === "--directory") return true;
    if (f.startsWith("--")) continue;
    for (const ch of f.slice(1)) { if (ch === "d") return true; if ("IwT".includes(ch)) break; }
  }
  return false;
}
const LISTS = new Set(["ls", "dir", "vdir", "du", "tree"]);
const DEFAULT_DOT = new Set(["ugrep", "ug", "rgrep", "find", "fd", "fdfind", "tree", "du", "ncdu", "rg", "ag", "ack", "grep", "egrep", "fgrep", "ls", "dir"]);
// The command word of a segment, past reserved words, assignments and wrappers.
function head(seg) {
  let k = 0, xargs = false;
  while (k < seg.length && KEYWORDS.has(seg[k])) k++;
  while (k < seg.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(seg[k])) k++;
  while (k < seg.length && WRAP.has(path.basename(seg[k]))) {
    const wname = path.basename(seg[k]);
    if (wname === "xargs") xargs = true;
    k++;
    while (k < seg.length && (/^-/.test(seg[k]) || /^[A-Za-z_][A-Za-z0-9_]*=/.test(seg[k]) || /^[0-9.]+[smhd]?$/.test(seg[k]))) {
      if (seg[k] === "--") { k++; break; }
      // `env -S 'cmd args'` splits its value into the command it runs.
      if (wname === "env" && /^(-S|--split-string)/.test(seg[k])) {
        const v = /^(-S|--split-string)$/.test(seg[k]) ? seg.slice(k + 1) : [seg[k].replace(/^(-S|--split-string=)/, ""), ...seg.slice(k + 1)];
        return { name: "eval", rest: v, xargs };
      }
      k += VALUED[wname] && VALUED[wname].test(seg[k]) ? 2 : 1;
    }
    // flock's lock file, before the command it runs.
    if (wname === "flock" && k < seg.length) {
      k++;
      if (/^(-c|--command)$/.test(seg[k] || "")) return { name: "eval", rest: seg.slice(k + 1), xargs };
    }
  }
  return k < seg.length ? { name: path.basename(seg[k]), rest: seg.slice(k + 1), xargs } : null;
}
// A shell that reads its commands from stdin (`| bash`, `sh -s`, `. /dev/stdin`): the heredocs of
// the command are what it runs.
function stdinShell(seg) {
  const hd = head(seg);
  if (!hd) return false;
  if (SHELLS.has(hd.name)) return !hd.rest.some((a) => /^-[A-Za-z]*c/.test(a)) && hd.rest.every((a) => /^-/.test(a));
  return (hd.name === "source" || hd.name === ".") && /^(-|\/dev\/stdin|\/proc\/self\/fd\/0|\/dev\/fd\/0)$/.test(hd.rest[0] || "");
}
let here = cwd, before = cwd, seen = 0;
// Past what it reads (nesting or length), the guard denies rather than let the rest through unread.
const tooMuch = () => report("the command, nested deeper or longer than the guard reads,", roots[0]);
// The segments being judged: what `xargs` reads may come from any of them (`echo ~ | xargs du`).
let group = [];
function walk(segs, depth) {
  if (depth > 16) tooMuch();
  const piped = segs.some(stdinShell);
  const outer = group;
  group = segs;
  for (const seg of segs) {
    if (++seen > 20000) tooMuch();
    judge(seg, depth, piped);
  }
  group = outer;
}
// An argument of the segments `segs` that names a root or a directory holding one: the output of a
// command (`$(echo ~)`, `$(realpath ../..)`) or what xargs reads may be that path (#311, independent
// review). Not read: each command's name, an option's value (`cut -d /`), and `/` alone, which is
// the separator of `tr`, `cut` and `sed` far more often than a path. `HOME` is the home
// (`$(printenv HOME)`).
const holderMemo = new WeakMap();
function namesHolder(segs, depth = 0) {
  for (const sg of segs) {
    // Read once per directory it is read from: relative words name another place after a `cd`.
    const m = holderMemo.get(sg);
    if (m && m.here === here) { if (m.o) { holderAt = m.at; return m.o; } continue; }
    const o = segHolder(sg, depth);
    holderMemo.set(sg, { here, o, at: holderAt });
    if (o) return o;
  }
  return null;
}
function segHolder(sg, depth) {
  for (let j = 1; j < sg.length; j++) {
    const w = sg[j];
    if (typeof w !== "string" || !w || w === "/" || /^-/.test(w) || /^-/.test(sg[j - 1])) continue;
    // A path a substitution prints (`$(dirname $(dirname ~/x/y))`): what it names, one level up
    // for each `dirname`.
    const inner = subOnly(w);
    if (inner !== null) { if (depth < 8) { const o = namesHolder(words(inner), depth + 1); if (o) return o; } continue; }
    if (/[*?[{]/.test(shellPath(w))) continue;
    const x = w === "HOME" ? home : expand(shellPath(w));
    if (!x) continue;
    let p = path.isAbsolute(x) ? x : path.resolve(here, x);
    if (sg[0] === "dirname") p = path.dirname(p);
    const o = holder(p) || hit(p);
    if (o) { holderAt = p; return o; }
  }
  return null;
}
let holderAt = "";
// The command of a word that is a substitution and nothing else (`$(echo ~)`, `"$(pwd)/"`): the path
// is its output. With text around it (`$(pwd)/src`) the path is another one.
const subOnly = (a) => { const m = /^(?:\$\(([\s\S]*)\)|`([\s\S]*)`)\/?$/.exec(a); return m ? (m[1] !== undefined ? m[1] : m[2]) : null; };
function judge(seg, depth, piped) {
  const hd = head(seg);
  if (!hd) return;
  const name = hd.name;
  let rest = hd.rest;
  // The script of `bash -c '…'` (`su -c`, `script -c`), the words of `eval` and `watch`, and a heredoc
  // a shell runs are commands of their own, read in turn.
  if (RUNS_C.has(name)) {
    const eq = rest.find((a) => /^--command=/.test(a));
    if (eq) { walk(words(eq.slice(10)), depth + 1); return; }
    const c = rest.findIndex((a) => /^-[A-Za-z]*c[A-Za-z]*$/.test(a) || a === "--command");
    if (c >= 0) {
      let s = c + 1;
      if (rest[s] === "--") s++;
      if (s < rest.length) { walk(words(rest[s]), depth + 1); return; }
    }
  }
  if (name === "eval" && rest.length) { walk(words(rest.join(" ")), depth + 1); return; }
  if (name === "watch") { walk(words(rest.filter((a, j) => !/^-/.test(a) && !/^(-[nq]|--interval|--equexit)$/.test(rest[j - 1] || "")).join(" ")), depth + 1); return; }
  if (seg.docs && (SHELLS.has(name) || piped)) for (const d of seg.docs) walk(words(d), depth + 1);
  // `xargs cmd <<EOF`: the lines are cmd's arguments.
  if (seg.docs && hd.xargs) rest = rest.concat(seg.docs.join("\n").split(/\s+/).filter(Boolean));
  rest0 = rest;
  const flags = rest.filter((a) => /^-/.test(a));
  let args = rest.filter((a) => !/^-/.test(a) && a !== "");
  // find: only its start points are paths (`-name dir` is a pattern), and what -exec runs is a command.
  if (name === "find") {
    let j = 0;
    while (/^-([HLP]|D\S*|O[0-9])$/.test(rest[j] || "")) j++;
    if (rest[j] === "--") j++;
    const starts = [];
    for (; j < rest.length && !/^[-(!]/.test(rest[j]); j++) starts.push(rest[j]);
    for (let e = j; e < rest.length; e++) {
      if (!/^-(exec|execdir|ok|okdir)$/.test(rest[e])) continue;
      let f = e + 1;
      while (f < rest.length && rest[f] !== ";" && rest[f] !== "+") f++;
      walk([rest.slice(e + 1, f)], depth + 1);
      e = f;
    }
    args = starts.filter((a) => a !== "");
  }
  const at = (a) => {
    const x = expand(shellPath(a));
    return x === null ? null : path.isAbsolute(x) ? x : here + "/" + x;
  };
  if (name === "cd" || name === "pushd") {
    // Into a directory a command prints (`cd $(echo ~)`): where that command names, when it names a
    // directory that holds a root.
    const sub = args.length ? subOnly(args[0]) : null;
    const t = args[0] === "-" ? before : sub !== null ? (namesHolder(words(sub)) ? holderAt : null) : args.length ? at(args[0]) : home || null;
    if (t) {
      h = hit(t);
      if (h) report("the command (" + name + " " + (args[0] || "") + ")", h);
      before = here;
      here = t;
    }
    return;
  }
  const rec = recursive(name, flags);
  const cands = args.slice();
  // A flag's value (`-C ~`, `--directory=~`) may be where it reads.
  for (let j = 0; j < rest.length && name !== "find"; j++) {
    const m = /^--?[A-Za-z-]+=(.+)$/.exec(rest[j]);
    if (m) cands.push(m[1]);
  }
  // A recursive read that leaves out every directory with the root's name, in that tool's own syntax
  // and with nothing else on the line undoing it: find `[-type d] -name dir -prune -o …` first in
  // its expression (no -depth/-delete, which descend before pruning), grep `--exclude-dir=dir`, the
  // last rg/ugrep glob `-g '!dir'`, ag `--ignore dir`, fd `-E dir`, rsync `--exclude=dir` with no
  // include or filter rule, tar `--exclude=dir` unanchored. Any other exclusion (grep's `--exclude`,
  // `-not -name dir`, a path such as `x/dir`) still walks into it.
  const lastGlob = rest.reduce((n, a, j) => (/^(-g|--glob|--iglob)(=|$)/.test(a) ? j : n), -1);
  const findLeaves = (o, b) => {
    if (rest.some((a) => a === "-depth" || a === "-d" || a === "-delete")) return false;
    let j = 0;
    while (/^-[HLP]$/.test(rest[j] || "")) j++;
    while (j < rest.length && !/^[-(!]/.test(rest[j])) j++;
    for (;;) {
      if (/^-(maxdepth|mindepth)$/.test(rest[j] || "")) j += 2;
      else if (/^-(xdev|mount|noleaf|ignore_readdir_race|daystart)$/.test(rest[j] || "")) j++;
      else break;
    }
    const open = rest[j] === "(";
    if (open) j++;
    if (rest[j] === "-type" && rest[j + 1] === "d") { j += 2; if (rest[j] === "-a") j++; }
    const f = rest[j], v = rest[j + 1];
    if (typeof v !== "string") return false;
    const named = (/^-i?name$/.test(f) && compMatch(v, b)) || (/^-i?(path|wholename)$/.test(f) && (v === "*/" + b || v === o.abs || v === o.real));
    if (!named) return false;
    j += 2;
    if (rest[j] === "-a") j++;
    if (rest[j] !== "-prune") return false;
    j++;
    if (open) { if (rest[j] !== ")") return false; j++; }
    return rest[j] === "-o" || j >= rest.length;
  };
  const leaves = (o) => {
    const b = path.basename(o.abs);
    if (name === "find") return findLeaves(o, b);
    for (let j = 0; j < rest.length; j++) {
      const m = /^(--?[A-Za-z-]+)=([\s\S]*)$/.exec(rest[j]);
      const f = m ? m[1] : rest[j], v = m ? m[2] : rest[j + 1];
      if (typeof v !== "string") continue;
      if (/grep$|^ug$/.test(name) && f === "--exclude-dir" && dirGlob(v, b)) return true;
      if (/^(rg|ugrep|ug)$/.test(name) && j === lastGlob && /^(-g|--glob|--iglob)$/.test(f) && v.startsWith("!") && dirGlob(v.slice(1), b)) return true;
      if (name === "ag" && /^--ignore(-dir)?$/.test(f) && dirGlob(v, b)) return true;
      if (/^fd(find)?$/.test(name) && /^(-E|--exclude)$/.test(f) && dirGlob(v, b)) return true;
      if (name === "rsync" && f === "--exclude" && dirGlob(v, b) && !rest.some((a) => /^--(include|filter|include-from|exclude-from|files-from|cvs-exclude)/.test(a) || /^-[A-Za-z]*[fFC]/.test(a))) return true;
      if (/tar$/.test(name) && f === "--exclude" && dirGlob(v, b) && !rest.includes("--anchored")) return true;
    }
    return false;
  };
  // A depth limit (`find -maxdepth`, `tree -L`, `du -d`) is not read: du walks everything under it
  // anyway, and every tool spells and repeats it its own way (#311, third review).
  const holds = (p) => { const o = holder(p); return o && !leaves(o) ? o : null; };
  // Where a copy or an extraction writes is not read: the last word of cp/mv/rsync/scp (unless
  // `-t DIR` names it), and every directory of `tar -x`. What lands under a root is still a word under it.
  const extract = /tar$/.test(name) && (flags.some((f) => /^-[A-Za-z]*x/.test(f) || f === "--extract") || /^[A-Za-z]*x[A-Za-z]*$/.test(rest[0] || ""));
  const target = /^(cp|mv)$/.test(name) && flags.some((f) => /^-[A-Za-z]*t/.test(f) || /^--target-directory/.test(f));
  const dest = /^(cp|mv|rsync|scp)$/.test(name) && args.length > 1 && !target ? args[args.length - 1] : null;
  const lists = LISTS.has(name) && !(name === "ls" && lsDir(flags));
  // A path the shell computes is judged by what computes it, and xargs' by the pipeline that feeds
  // it (`echo ~ | cat | xargs du`).
  if (rec || lists) {
    for (const a of cands) {
      const t = subOnly(a);
      if (t === null) continue;
      h = namesHolder(words(t));
      if (h) report("the command (" + name + " " + a + "), whose path a command computes from a directory that holds", h);
    }
    const k = group.indexOf(seg);
    if (hd.xargs && k > 0) {
      let f = k;
      while (f > 0 && group[f - 1].pipe) f--;
      h = namesHolder(group.slice(f, k));
      if (h) report("the command (xargs " + name + "), whose arguments may come from a directory that holds", h);
    }
  }
  for (const a of cands) {
    const p = at(a);
    if (p === null) continue;
    const reads = rec && !extract && a !== dest;
    if (/[*?[{]/.test(a)) {
      h = globHit(path.resolve(p), reads, reads || lists);
      if (h && rec && leaves(h)) h = null;
    } else {
      h = hit(p) || (reads ? holds(p) : null);
    }
    if (h) report("the command (" + name + " " + a + ")", h);
  }
  if (rec && DEFAULT_DOT.has(name) && args.length <= (/grep$|^rg$|^ag$|^ack$/.test(name) ? 1 : 0)) {
    h = holds(here);
    if (h) report("the command (" + name + " from " + here + ", which holds", h);
  }
}
walk(words(cmd), 0);
JS

# Without node nothing can read the command (see header), but forbidden_paths still holds, in pure
# bash and by the text alone: the policy's entries read with a pattern, and any spelling of one
# (`~/<dir>`, `$HOME/<dir>`, `${HOME}/<dir>`, the absolute path) anywhere in the hook input — the
# command, a file tool's path, the session's directory — is denied (#311 (a)). Cruder than the node
# rule, and strict: it errs toward denying.
check_forbidden_paths_bare() {
  local text="" body e abs rel h sp
  # The list, its strings read whole (a `]` inside one does not end it), then each string.
  local list_re='"forbidden_paths"[[:space:]]*:[[:space:]]*\[(([[:space:],]|"([^"\\]|\\.)*")*)\]'
  local -a entries=()
  if [ "$PUBLISHED" -eq 1 ] && [ -z "${BASH_GUARD_POLICY:-}" ]; then
    text="$(git_clean -C "$PUBLISHED_PROJECT" show "origin/HEAD:scripts/hooks/guard.policy.json" 2>/dev/null || true)"
  elif [ -r "$POLICY_FILE" ]; then
    text="$(cat "$POLICY_FILE" 2>/dev/null || true)"
  fi
  [[ "$text" =~ $list_re ]] || return 0
  body="${BASH_REMATCH[1]}"
  while [[ "$body" =~ \"(([^\"\\]|\\.)+)\"(.*)$ ]]; do
    entries+=("${BASH_REMATCH[1]}")
    body="${BASH_REMATCH[3]}"
  done
  h="${BASH_GUARD_HOME:-${HOME:-}}"
  h="${h%/}"
  # shellcheck disable=SC2088 # the policy entry as written, a literal tilde
  for e in ${entries[@]+"${entries[@]}"}; do
    case "$e" in
      "~/"?*) rel="${e#\~/}"; rel="${rel%/}"; abs="${h:+$h/$rel}" ;;
      /?*) abs="${e%/}"; rel=""; [ -n "$h" ] && [[ "$abs" == "$h/"* ]] && rel="${abs#"$h"/}" ;;
      *) continue ;;
    esac
    for sp in ${abs:+"$abs"} ${rel:+"~/$rel" "\$HOME/$rel" "\${HOME}/$rel"}; do
      # With a path boundary after it: `~/<dir>s` is another directory.
      if [[ "$INPUT" == *"$sp" || "$INPUT" == *"$sp"[!A-Za-z0-9_.-]* ]]; then
        deny "the hook input names ${sp}, which this repository's guard.policy.json keeps out of every session (forbidden_paths), and without node the guard reads it by the text alone" \
          "leave it alone; and install node (>= 24), which the guard needs to read commands"
      fi
    done
  done
  return 0
}

check_forbidden_paths() {
  local out what entry
  [ "${#FORBIDDEN_PATHS[@]}" -gt 0 ] || return 0
  local rc=0
  out="$(printf '%s' "$INPUT" | node -e "$FORBID_JS" "${BASH_GUARD_HOME:-${HOME:-}}" "${FORBIDDEN_PATHS[@]}" 2>/dev/null)" || rc=$?
  # A reader that fails (a stack overflow on thousands of nested `"$(`, found in the independent
  # review of #311) has judged nothing: denied, as the main reader's failures are.
  if [ "$rc" -ne 0 ]; then
    deny "the guard could not read this command for the paths this repository's guard.policy.json keeps out of every session (forbidden_paths), and a command it cannot read is not let through" \
      "split it into simpler commands"
  fi
  [ -n "$out" ] || return 0
  what="${out%%$'\t'*}"
  entry="${out#*$'\t'}"
  deny "${what} touches ${entry}, which this repository's guard.policy.json keeps out of every session (forbidden_paths)" \
    "leave it alone and use synthetic fixtures; if you only need to MENTION the path in a text, write that file with the Write/Edit tool"
}

# The hook input, read once: the extractor reads it, and so may the rules that need another
# field of it (the session's directory, the path of a file tool).
# The guard's time limit, GUARD_SECONDS from its start, under the smallest hook timeout of the fleet
# (15 s): a hook that runs past the harness's timeout lets the command run. The extractor runs under
# it (coreutils timeout, where there is one): one stuck on a command it read pathologically was a way
# to that (found 2026-10-03, verifying #299: 34 nested `$((`, and the node left behind kept a CPU
# busy for hours after the hook was killed). Judging stops there too (GUARD_DEADLINE). A command the
# guard cannot read and judge in time is denied, not let through, and so is one it fails on (see the
# supervisor below). TEST-ONLY override: BASH_GUARD_SECONDS.
INPUT="$(cat)"
GUARD_SECONDS=10
[[ "${BASH_GUARD_SECONDS:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]] && GUARD_SECONDS="$BASH_GUARD_SECONDS"
GUARD_DEADLINE="${GUARD_SECONDS%.*}"

# guard_judge: read the command and judge it. Exits 0 (allow) or 2 (deny, with its reason on stderr);
# run by the supervisor below, which decides what any other ending means.
guard_judge() {
  local rc=0
  [ -n "${EXTRACT_JS:-}" ] || deny "the guard could not load its command reader, and a command it cannot read is not let through" \
    "check that this guard's file is readable and whole (scripts/hooks/bash-guard.sh)"
  # The input goes to the extractor through a pipe, not a here-string: past 64 KiB bash writes a
  # here-string to a temporary file, and with /tmp full the extractor read nothing and every such
  # command ran (found 2026-10-03, third verification round of #299: a file written with a heredoc
  # of 70 KB, then `git push --force`).
  # A file tool's input has no "command" key (inside a JSON string a quote is escaped, so the key
  # with its bare quotes appears only as a key; JSON spells a letter otherwise only as \u, and an
  # input with one is read whole): its reader would read nothing, and is not started.
  # Two node processes for a Read instead of three (#311 (c)).
  if [[ "$INPUT" != *'"command"'* && "$INPUT" != *'\u'* ]]; then
    command -v node >/dev/null 2>&1 || rc=127
    SEGMENTS=""
  elif command -v timeout >/dev/null 2>&1; then
    SEGMENTS="$(printf '%s' "$INPUT" | timeout -k 2 "$GUARD_SECONDS" node -e "$EXTRACT_JS" 2>/dev/null)" || rc=$?
  else
    SEGMENTS="$(printf '%s' "$INPUT" | node -e "$EXTRACT_JS" 2>/dev/null)" || rc=$?
  fi
  case "$rc" in
    0) ;;
    124 | 137)
      deny "the guard could not read this command within ${GUARD_SECONDS} s, and a command it cannot read is not let through" \
        "split it into shorter commands, with less nesting"
      ;;
    # No node (timeout's 127 and 126, like the shell's): nothing can read the command (see header),
    # and only forbidden_paths holds, by the text alone.
    126 | 127)
      SEGMENTS=""
      command -v node >/dev/null 2>&1 || check_forbidden_paths_bare
      ;;
    *)
      deny "the guard's command reader failed on this command (exit ${rc}), and a command it cannot read is not let through" \
        "split it into shorter commands"
      ;;
  esac
  if [ -z "$SEGMENTS" ]; then
    # No Bash command to read: only forbidden_paths can apply (a file tool wired to this guard).
    # Otherwise fail-open: nothing to evaluate (see header).
    load_policy
    check_forbidden_paths
    GUARD_ALLOWED=1
    exit 0
  fi

  load_policy
  check_forbidden_paths

  judge_segments "$SEGMENTS"
  # A deny past the deadline inside a substitution (`dst="$(push_head_branch)"`) may not have stopped it.
  check_deadline

  GUARD_ALLOWED=1
  exit 0
}

# guard_kill_tree <pid>: stops <pid> and every process under it, then kills them all. Stopped first,
# and the tree walked again, so that none forks a process the walk would miss.
guard_kill_tree() {
  local all=" $1 " table k more
  local -a t=()
  [ -n "$1" ] || return 0
  kill -STOP "$1" 2>/dev/null || true
  set -f
  for _ in 1 2 3; do
    table="$(ps -A -o pid= -o ppid= 2>/dev/null)" || table=""
    # shellcheck disable=SC2206 # "<pid> <ppid>" pairs, every line of them; globbing is off
    t=($table)
    more=1
    while [ "$more" -eq 1 ]; do
      more=0
      for ((k = 0; k + 1 < ${#t[@]}; k += 2)); do
        [[ "$all" == *" ${t[k+1]} "* && "$all" != *" ${t[k]} "* ]] || continue
        all+="${t[k]} "
        kill -STOP "${t[k]}" 2>/dev/null || true
        more=1
      done
    done
  done
  # shellcheck disable=SC2086 # one pid per word
  kill -KILL $all 2>/dev/null || true
}

# --- The supervisor ------------------------------------------------------------
# The guard judges in a child process and this one waits for its verdict, GUARD_SECONDS and one more
# at most. The limit inside the judge (check_deadline) is only looked at between segments, and a
# single segment could keep it busy for minutes: 6,000 `$()` in front of a `git push --force`, the
# command word read a character at a time, or a word of 1 MB (found 2026-10-03, third verification
# round of #299). Past that second, or if the judge dies without a verdict, this process stops
# it and everything it started, and denies. And any ending of the judge other than allow (0) or deny
# (2) is a failure of the guard (bash stops a script under `set -e` with exit 1, for instance when it
# cannot write a here-string to a full /tmp): denied too. Claude Code blocks only on exit 2, so a
# crash used to let the command run; now only a missing node does (see header).
case "$GUARD_SECONDS" in
  *.*) GUARD_WAIT="$((10#${GUARD_SECONDS%%.*} + 1)).${GUARD_SECONDS#*.}" ;;
  *) GUARD_WAIT="$((10#$GUARD_SECONDS + 1))" ;;
esac
# The bash 3.2 of macOS waits whole seconds only: the next one up.
[ "${BASH_VERSINFO[0]}" -ge 4 ] || [[ "$GUARD_WAIT" != *.* ]] || GUARD_WAIT="$((10#${GUARD_WAIT%%.*} + 1))"
# Killed itself (the harness gives up on the hook), it takes the judge and what the judge started along.
GUARD_JUDGE_PID=""
trap '[ -z "$GUARD_JUDGE_PID" ] || guard_kill_tree "$GUARD_JUDGE_PID"; exit 143' TERM INT HUP
# The judge writes its exit status on fd 9 as it ends (its EXIT trap, guard_verdict), and keeps this
# hook's stdout (fd 7 meanwhile; /dev/null when the hook has none).
# guard_verdict <exit status>: an allow (0) counts only where guard_judge allows (GUARD_ALLOWED). The
# bash 3.2 of macOS shows 0 to the EXIT trap of a script an error stopped (`${v,,}`, an empty array
# under `set -u`), so that a failure would read as an allow.
GUARD_ALLOWED=0
guard_verdict() {
  local rc="$1"
  [ "$rc" -ne 0 ] || [ "$GUARD_ALLOWED" -eq 1 ] || rc=1
  printf '%s\n' "$rc" >&9
}
{ exec 7>&1; } 2>/dev/null || exec 7>/dev/null
exec 8< <(exec 9>&1 1>&7 7>&-; GUARD_SUPERVISED=1; trap 'guard_verdict "$?"' EXIT; guard_judge)
GUARD_JUDGE_PID="${!:-}"
exec 7>&-
GUARD_RC=""
GUARD_READ=0
read -r -t "$GUARD_WAIT" -u 8 GUARD_RC || GUARD_READ=$?
case "$GUARD_READ:$GUARD_RC" in
  0:0) exit 0 ;;
  0:2) exit 2 ;;
  0:*)
    deny "the guard failed while judging this command (exit ${GUARD_RC}), and a command it cannot judge is not let through" \
      "split it into shorter commands"
    ;;
esac
guard_kill_tree "$GUARD_JUDGE_PID"
# Out of time: read says so above 128; the bash 3.2 of macOS says 1, as at the end of the input.
if [ "$GUARD_READ" -gt 128 ] || [ "$SECONDS" -ge "$GUARD_DEADLINE" ]; then
  deny "the guard could not judge this command within ${GUARD_SECONDS} s, and a command it cannot judge is not let through" \
    "split it into shorter commands"
fi
deny "the guard stopped before judging this command, and a command it cannot judge is not let through" \
  "split it into shorter commands"
