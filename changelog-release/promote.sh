#!/usr/bin/env bash
# changelog-release — promote the Keep-a-Changelog [Unreleased] section to a versioned heading.
#
# Inputs via env (set by action.yml):
#   VERSION         X.Y.Z (required)
#   CHANGELOG_PATH  path to the changelog (default CHANGELOG.md)
#   DATE            YYYY-MM-DD; empty → today UTC
#   GITHUB_OUTPUT   output file (provided by Actions)
#
# Effect: rewrites the file so that
#     ## [Unreleased]
#     <entries>
# becomes
#     ## [Unreleased]
#
#     ## [X.Y.Z] - YYYY-MM-DD
#     <entries>
# i.e. a fresh empty [Unreleased] on top and the moved entries under the new version.
# Emits `notes` = the moved entries (multiline, via heredoc).
# Missing changelog → no-op, empty notes, a warning (never fails).
set -euo pipefail

: "${VERSION:?VERSION is required}"
CHANGELOG_PATH="${CHANGELOG_PATH:-CHANGELOG.md}"
DATE="${DATE:-}"
if [ -z "$DATE" ]; then
  DATE="$(date -u +%F)"
fi

emit_empty_notes() {
  {
    echo "notes<<__CHANGELOG_NOTES_EOF__"
    echo "__CHANGELOG_NOTES_EOF__"
  } >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
}

if [ ! -f "$CHANGELOG_PATH" ]; then
  echo "::warning::changelog-release: '$CHANGELOG_PATH' not found — skipping promotion (empty notes)."
  emit_empty_notes
  exit 0
fi

# Do the surgery in node: robust, no fragile multi-pattern sed across the whole file.
# It locates the first `## [Unreleased]` heading (case-insensitive on the word),
# captures the body up to the next `## ` heading (or EOF), and rewrites the file.
notes_file="$(mktemp)"
NOTES_FILE="$notes_file" VERSION="$VERSION" DATE="$DATE" CHANGELOG_PATH="$CHANGELOG_PATH" node -e '
  const fs = require("fs");
  const path = process.env.CHANGELOG_PATH;
  const version = process.env.VERSION;
  const date = process.env.DATE;
  const notesFile = process.env.NOTES_FILE;

  const raw = fs.readFileSync(path, "utf8");
  const eol = raw.includes("\r\n") ? "\r\n" : "\n";
  const lines = raw.split(/\r?\n/);

  // Find the Unreleased heading: a level-2 ATX heading whose text is "[Unreleased]".
  const isUnreleased = (l) => /^##\s+\[Unreleased\]\s*$/i.test(l);
  const isH2 = (l) => /^##\s+/.test(l);

  let idx = lines.findIndex(isUnreleased);
  if (idx === -1) {
    // No Unreleased section → nothing to promote. Leave file untouched, empty notes.
    process.stderr.write("changelog-release: no [Unreleased] section in " + path + " — leaving file unchanged (empty notes).\n");
    fs.writeFileSync(notesFile, "");
    process.exit(0);
  }

  // Body runs from the line after the heading to the next H2 (exclusive) or EOF.
  let end = idx + 1;
  while (end < lines.length && !isH2(lines[end])) end++;

  const bodyLines = lines.slice(idx + 1, end);
  // Trim leading/trailing blank lines for the captured notes.
  const trimmed = bodyLines.slice();
  while (trimmed.length && trimmed[0].trim() === "") trimmed.shift();
  while (trimmed.length && trimmed[trimmed.length - 1].trim() === "") trimmed.pop();
  const notes = trimmed.join("\n");
  fs.writeFileSync(notesFile, notes);

  // Rebuild: keep everything before the Unreleased heading, then a fresh empty
  // Unreleased, then the new versioned heading carrying the old body, then the rest.
  const before = lines.slice(0, idx);             // up to (excluding) the heading
  const after = lines.slice(end);                 // from the next H2 onward

  const rebuilt = []
    .concat(before)
    .concat(["## [Unreleased]", ""])              // fresh empty Unreleased + blank line
    .concat(["## [" + version + "] - " + date])   // new version heading
    .concat([""])                                 // always a blank line after the heading
    .concat(trimmed)                              // the moved (trimmed) entries
    .concat([""])                                 // always a blank line after the section
    .concat(after);

  // Normalise: collapse any run of 2+ blank lines to a single blank line. (The empty
  // Unreleased / empty body cases would otherwise leave a double blank between H2s.)
  let text = rebuilt.join(eol);
  const triple = eol + eol + eol;     // = one blank line is eol+eol; two blanks is eol*3
  while (text.includes(triple)) text = text.replace(triple, eol + eol);
  // Ensure a single trailing newline.
  text = text.replace(/(\r?\n)+$/, "") + eol;

  fs.writeFileSync(path, text);
  process.stderr.write("changelog-release: promoted [Unreleased] -> [" + version + "] - " + date + " in " + path + "\n");
'

# Stream the captured notes into $GITHUB_OUTPUT with a heredoc (multiline-safe).
{
  echo "notes<<__CHANGELOG_NOTES_EOF__"
  cat "$notes_file"
  echo
  echo "__CHANGELOG_NOTES_EOF__"
} >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

rm -f "$notes_file"
