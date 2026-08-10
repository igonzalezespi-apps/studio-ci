#!/usr/bin/env bash
# apply-version — write a version into a repo's manifests, per stack `kind`.
#
# Inputs via env (set by action.yml):
#   VERSION            X.Y.Z (required)
#   KIND               npm-root | npm-monorepo | flutter | expo (required)
#   BUILD_NUMBER_FILE  flutter only: path to a committed build-number counter
#   GITHUB_OUTPUT      output file (provided by Actions)
#
# Emits: files-changed (space-separated, for the caller to git add).
set -euo pipefail

: "${VERSION:?VERSION is required}"
: "${KIND:?KIND is required}"
BUILD_NUMBER_FILE="${BUILD_NUMBER_FILE:-}"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "apply-version: version '$VERSION' is not X.Y.Z" >&2
  exit 1
fi

files_changed=""
add_file() { files_changed="${files_changed:+$files_changed }$1"; }

# Set the top-level "version" field of a package.json via node (no jq dependency).
# Preserves 2-space indentation and a trailing newline (npm's own convention).
set_pkg_version() {
  local pkg="$1"
  VERSION="$VERSION" PKG="$pkg" node -e '
    const fs = require("fs");
    const p = process.env.PKG;
    const j = JSON.parse(fs.readFileSync(p, "utf8"));
    j.version = process.env.VERSION;
    fs.writeFileSync(p, JSON.stringify(j, null, 2) + "\n");
  '
}

case "$KIND" in
  npm-root)
    [ -f package.json ] || { echo "apply-version: package.json not found" >&2; exit 1; }
    set_pkg_version package.json
    add_file package.json
    ;;

  npm-monorepo)
    # Lockstep: every workspace package.json (and the root) gets the same version.
    # We do NOT rely on `pnpm version` semantics (which differ across pnpm majors and
    # can refuse on private/root packages); a node walk over workspace manifests is
    # deterministic and tool-version-independent.
    [ -f package.json ] || { echo "apply-version: root package.json not found" >&2; exit 1; }
    # Discover workspace package.json files: every package.json except those under
    # node_modules. This covers packages/* and apps/* layouts without parsing globs.
    mapfile -t pkgs < <(find . -name package.json -not -path '*/node_modules/*' | sort)
    if [ "${#pkgs[@]}" -eq 0 ]; then
      echo "apply-version: no package.json files found" >&2
      exit 1
    fi
    for p in "${pkgs[@]}"; do
      set_pkg_version "$p"
      # Normalise ./foo/package.json -> foo/package.json for a tidy files-changed list.
      add_file "${p#./}"
    done
    ;;

  flutter)
    [ -f pubspec.yaml ] || { echo "apply-version: pubspec.yaml not found" >&2; exit 1; }
    # Build number: a committed monotonic counter. Absent → start at 1; else increment.
    build=1
    if [ -n "$BUILD_NUMBER_FILE" ] && [ -f "$BUILD_NUMBER_FILE" ]; then
      cur="$(tr -dc '0-9' < "$BUILD_NUMBER_FILE")"
      if [ -n "$cur" ]; then
        build=$((cur + 1))
      fi
    fi
    if [ -n "$BUILD_NUMBER_FILE" ]; then
      mkdir -p "$(dirname "$BUILD_NUMBER_FILE")"
      printf '%s\n' "$build" > "$BUILD_NUMBER_FILE"
      add_file "$BUILD_NUMBER_FILE"
    fi
    # pubspec version line: `version: X.Y.Z+N`. Replace the first top-level `version:`.
    VERSION="$VERSION" BUILD="$build" node -e '
      const fs = require("fs");
      const p = "pubspec.yaml";
      const lines = fs.readFileSync(p, "utf8").split(/\r?\n/);
      const want = "version: " + process.env.VERSION + "+" + process.env.BUILD;
      let done = false;
      for (let i = 0; i < lines.length; i++) {
        // top-level key (no leading whitespace) named version
        if (/^version:\s*/.test(lines[i])) { lines[i] = want; done = true; break; }
      }
      if (!done) { console.error("apply-version: no top-level version: line in pubspec.yaml"); process.exit(1); }
      fs.writeFileSync(p, lines.join("\n"));
    '
    add_file pubspec.yaml
    ;;

  expo)
    # Expo: NO build number. Set root package.json version AND the version: field in
    # the TS app config. Both must land or the stores see a mismatch.
    [ -f package.json ] || { echo "apply-version: package.json not found" >&2; exit 1; }
    set_pkg_version package.json
    add_file package.json

    cfg="apps/movies/app.config.ts"
    [ -f "$cfg" ] || { echo "apply-version: $cfg not found" >&2; exit 1; }
    # Replace the value of the first `version:` property in the TS config. We match
    # `version:` followed by a quoted string and swap only the string, preserving the
    # quote style and surrounding formatting. node, not sed, to avoid quoting hazards.
    VERSION="$VERSION" CFG="$cfg" node -e '
      const fs = require("fs");
      const p = process.env.CFG;
      const v = process.env.VERSION;
      let src = fs.readFileSync(p, "utf8");
      // version: "x"  |  version: '\''x'\''  (first occurrence only)
      const re = /(\bversion\s*:\s*)(["'\''])([^"'\'']*)\2/;
      if (!re.test(src)) { console.error("apply-version: no version: \"...\" field in " + p); process.exit(1); }
      src = src.replace(re, (_m, lead, q) => lead + q + v + q);
      fs.writeFileSync(p, src);
    '
    add_file "$cfg"
    ;;

  *)
    echo "apply-version: unknown kind '$KIND' (expected npm-root | npm-monorepo | flutter | expo)" >&2
    exit 1
    ;;
esac

printf 'files-changed=%s\n' "$files_changed" >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
echo "apply-version: kind=$KIND version=$VERSION wrote: $files_changed"
