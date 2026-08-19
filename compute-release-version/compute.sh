#!/usr/bin/env bash
# compute-release-version — derive the next semver from semver:* PR labels.
#
# Stack-agnostic. Inputs come in via env (set by action.yml):
#   CURRENT_VERSION  X.Y.Z (required)
#   BASE_REF         last release tag, or "" → auto-detect latest tag matching TAG_PREFIX*
#   BASE_BRANCH      branch the release PRs merged into (default "develop")
#   TAG_PREFIX       tag prefix (default "v")
#   ALLOW_MAJOR      "true" lets a semver:major label bump the MAJOR (default "false" → cap at minor)
#   GH_TOKEN         token for gh (required)
#   GITHUB_REPOSITORY  owner/repo (provided by Actions)
#   GITHUB_OUTPUT      output file (provided by Actions)
#
# Emits: bump, bump-requested, major-capped, next-version, next-tag, should-release, pr-numbers.
set -euo pipefail

: "${CURRENT_VERSION:?CURRENT_VERSION is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
BASE_REF="${BASE_REF:-}"
TAG_PREFIX="${TAG_PREFIX:-v}"
# Default "develop" keeps every product working unchanged: they are develop→main.
# It is an INPUT because trunk→main repos have no develop at all, and there the
# hardcoded value made this action silently unusable — see the note below.
BASE_BRANCH="${BASE_BRANCH:-develop}"
# Default "false" ON PURPOSE, and it is the whole point of this knob: a dependency's major is not
# the product's major. Renovate labels every major dependency bump `semver:major` (correctly — it
# describes the DEPENDENCY), and this action folds the highest label in range into the PRODUCT's
# version. With nothing in between, one `actions/setup-node@v6→v7` cut a 1.0.0 on a product whose
# owner had decided the day before that 1.0 was reserved for the first working MVP. Capping at
# minor keeps a pre-1.0 product inside 0.x no matter what the bots merge, because 0.x can never
# reach 1.0.0 by minor bumps — so reaching 1.0.0 becomes an explicit act instead of an accident.
ALLOW_MAJOR="${ALLOW_MAJOR:-false}"

# --- validate current version is X.Y.Z -------------------------------------
if [[ ! "$CURRENT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "compute-release-version: current-version '$CURRENT_VERSION' is not X.Y.Z" >&2
  exit 1
fi

emit() { printf '%s=%s\n' "$1" "$2" >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"; }

# --- pure-bash semver increment --------------------------------------------
# apply_bump <X.Y.Z> <major|minor|patch|none>  -> prints the next X.Y.Z
apply_bump() {
  local ver="$1" bump="$2" major minor patch
  IFS='.' read -r major minor patch <<<"$ver"
  case "$bump" in
    major) major=$((major + 1)); minor=0; patch=0 ;;
    minor) minor=$((minor + 1)); patch=0 ;;
    patch) patch=$((patch + 1)) ;;
    none)  : ;;  # unchanged
    *) echo "apply_bump: unknown bump '$bump'" >&2; return 1 ;;
  esac
  printf '%s.%s.%s\n' "$major" "$minor" "$patch"
}

# --- rank helpers: major>minor>patch>none ----------------------------------
rank() {
  case "$1" in
    major) echo 3 ;;
    minor) echo 2 ;;
    patch) echo 1 ;;
    none)  echo 0 ;;
    *)     echo -1 ;;
  esac
}

# --- resolve the base tag (for the range cutoff) ---------------------------
# If BASE_REF is empty, pick the latest tag matching TAG_PREFIX*. May be empty
# (no tags yet) → range = all merged PRs.
base_tag="$BASE_REF"
if [ -z "$base_tag" ]; then
  # git tags are not guaranteed to be fetched; ask the API instead so this works
  # regardless of checkout depth. Sort by version, highest first.
  base_tag=$(gh api "repos/$GITHUB_REPOSITORY/tags" --paginate --jq '.[].name' 2>/dev/null \
    | grep -E "^${TAG_PREFIX}[0-9]+\.[0-9]+\.[0-9]+$" \
    | sed "s/^${TAG_PREFIX}//" \
    | sort -t. -k1,1n -k2,2n -k3,3n \
    | tail -1 || true)
  if [ -n "$base_tag" ]; then
    base_tag="${TAG_PREFIX}${base_tag}"
  fi
fi

# --- resolve the cutoff date (mergedAt > this) -----------------------------
# If we have a base tag, find its commit date; PRs merged after it are in range.
cutoff=""
if [ -n "$base_tag" ]; then
  # tag ref → object; for an annotated tag we must deref to the commit.
  obj_type=$(gh api "repos/$GITHUB_REPOSITORY/git/refs/tags/$base_tag" \
    --jq '.object.type' 2>/dev/null || true)
  obj_sha=$(gh api "repos/$GITHUB_REPOSITORY/git/refs/tags/$base_tag" \
    --jq '.object.sha' 2>/dev/null || true)
  if [ -n "$obj_sha" ]; then
    if [ "$obj_type" = "tag" ]; then
      # annotated tag → resolve to the commit it points at
      obj_sha=$(gh api "repos/$GITHUB_REPOSITORY/git/tags/$obj_sha" \
        --jq '.object.sha' 2>/dev/null || true)
    fi
    if [ -n "$obj_sha" ]; then
      cutoff=$(gh api "repos/$GITHUB_REPOSITORY/commits/$obj_sha" \
        --jq '.commit.committer.date' 2>/dev/null || true)
    fi
  fi
  if [ -z "$cutoff" ]; then
    echo "compute-release-version: could not resolve commit date for tag '$base_tag'; treating range as all merged PRs" >&2
  fi
fi

# --- list merged PRs into the base branch ----------------------------------
# Defensive: if the list is empty or gh errors with no PRs, prs="[]".
#
# WHY THIS IS AN INPUT AND NOT THE LITERAL "develop":
# a trunk→main repo has no `develop` branch, so `--base develop` matched nothing, `prs` was
# always "[]", bump was always "none" and should-release always false — FOREVER, and without a
# single error. The action reported success while being structurally incapable of ever cutting a
# release there. A failure that never raises is worse than one that does: the four config repos
# had release workflows planned around a gate that could not go green.
prs=$(gh pr list \
  --repo "$GITHUB_REPOSITORY" \
  --base "$BASE_BRANCH" \
  --state merged \
  --limit 1000 \
  --json number,labels,mergedAt,title 2>/dev/null || echo "[]")
prs="${prs:-[]}"

# Filter to in-range PRs (mergedAt > cutoff when we have one) and extract, per
# PR, "<number>\t<semver-label-count>\t<space-joined-semver-labels>".
# Node does the JSON work (always present on Actions runners; used by ci-gate too).
parsed=$(CUTOFF="$cutoff" node -e '
  const fs = require("fs");
  const prs = JSON.parse(fs.readFileSync(0, "utf8") || "[]");
  const cutoff = process.env.CUTOFF || "";
  const cutMs = cutoff ? Date.parse(cutoff) : NaN;
  const out = [];
  for (const pr of prs) {
    if (cutoff) {
      const m = Date.parse(pr.mergedAt || "");
      // strictly AFTER the base tag commit date → excludes the tagged release PR itself
      if (!(m > cutMs)) continue;
    }
    const sem = (pr.labels || [])
      .map((l) => (l && l.name) || "")
      .filter((n) => /^semver:(major|minor|patch|none)$/.test(n))
      .map((n) => n.slice("semver:".length));
    out.push([String(pr.number), String(sem.length), sem.join(" ")].join("\t"));
  }
  process.stdout.write(out.join("\n"));
' <<<"$prs")

# --- walk the in-range PRs, require >=1 semver label, fold the HIGHEST bump ---
# A PR may carry SEVERAL semver labels: Renovate groups (e.g. npm-non-major,
# github-actions) bundle minor+patch updates and auto-label one per update type,
# so a grouped bot PR legitimately gets `semver:minor` AND `semver:patch`. Require
# at least one, and take the highest (major>minor>patch>none) — both for the PR
# and across the range. Only ZERO labels is an error (a mislabeled PR).
best="none"
pr_numbers=""
major_prs=""
had_pr=false

if [ -n "$parsed" ]; then
  while IFS=$'\t' read -r num count labels; do
    [ -z "$num" ] && continue
    had_pr=true
    if [ "${count:-0}" -lt 1 ] || [ -z "$labels" ]; then
      echo "compute-release-version: PR #$num has no semver:* label" >&2
      echo "  Every PR merged to develop in the release range must carry at least one of semver:major|minor|patch|none." >&2
      exit 1
    fi
    pr_numbers="${pr_numbers:+$pr_numbers }$num"
    # take this PR's highest-ranked label, then fold into the range best.
    for lbl in $labels; do
      if [ "$lbl" = "major" ]; then
        major_prs="${major_prs:+$major_prs }#$num"
      fi
      if [ "$(rank "$lbl")" -gt "$(rank "$best")" ]; then
        best="$lbl"
      fi
    done
  done <<<"$parsed"
fi

# No in-range PRs → none (set-e-safe: the loop above simply never ran).
if [ "$had_pr" != true ]; then
  best="none"
fi

bump_requested="$best"

# --- the major cap ----------------------------------------------------------
# Deliberately AFTER the fold and never before it: `bump-requested` must keep saying what the
# labels actually asked for, so the log can name the PRs instead of silently swallowing them. A
# cap that hides what it capped is how this went unnoticed the first time.
major_capped=false
bump="$best"
if [ "$bump" = "major" ] && [ "$ALLOW_MAJOR" != "true" ]; then
  bump="minor"
  major_capped=true
  echo "compute-release-version: MAJOR CAPPED -> minor (allow-major=$ALLOW_MAJOR)" >&2
  echo "  asked for major: ${major_prs:-<unknown>}" >&2
  echo "  A dependency's major is not the product's major. To cut a real major, set" >&2
  echo "  allow-major: true on this repo's release job, deliberately, for that release." >&2
fi

next_version=$(apply_bump "$CURRENT_VERSION" "$bump")
next_tag="${TAG_PREFIX}${next_version}"

if [ "$bump" = "none" ]; then
  should_release=false
else
  should_release=true
fi

emit "bump"           "$bump"
emit "bump-requested" "$bump_requested"
emit "major-capped"   "$major_capped"
emit "next-version"   "$next_version"
emit "next-tag"       "$next_tag"
emit "should-release" "$should_release"
emit "pr-numbers"     "$pr_numbers"

echo "compute-release-version: range base='${base_tag:-<none>}' cutoff='${cutoff:-<none>}'"
echo "compute-release-version: in-range PRs='${pr_numbers:-<none>}' bump=$bump (requested=$bump_requested, major-capped=$major_capped) $CURRENT_VERSION -> $next_version (tag $next_tag, should-release=$should_release)"
