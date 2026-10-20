#!/usr/bin/env bash
# pr-body.test.sh — renders every mode from a throwaway git repo and checks each body's shape.
# Then mutates pr_body.py and requires a failure.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${SUT_ROOT:-$HERE/..}"
PB="$ROOT/pr-body/pr-body.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT INT TERM
pass=0; fail=0
ok() { pass=$((pass + 1)); }
ko() { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | head -20; [ -n "${FAIL_FAST:-}" ] && exit 1; return 0; }

R="$TMP/repo"; mkdir -p "$R"
g() { git -C "$R" -c user.name=t -c user.email=t@x "$@" >/dev/null 2>&1; }
g init -q -b main
echo base > "$R/README.md"; g add -A; g commit -qm "chore: base"
g checkout -qb develop
for n in 12 13; do echo "$n" > "$R/f$n.txt"; g add -A; g commit -qm "feat: change $n (#$n)"; done
g checkout -qb feat/x
mkdir -p "$R/docs"; for i in $(seq 1 45); do echo "$i" > "$R/docs/f$i.md"; done
g add -A; g commit -qm "docs: many files"

printf 'Mueve la documentación a docs/ para que el índice la encuentre.\n' > "$TMP/summary"
printf 'bash x.test.sh: 12/12.\n' > "$TMP/verify"
printf 'Toca el flujo de merge: lo decides tú. Si algo falla, se revierte esta PR.\n' > "$TMP/why"
body() { (cd "$R" && "$PB" "$@" --repo-dir "$R" 2> "$TMP/err"); }

# work
body --base develop --mode work --summary-file "$TMP/summary" --verify-file "$TMP/verify" > "$TMP/work.md"; rc=$?
[ $rc -eq 0 ] && ok || ko "work renders (rc $rc)" "$(cat "$TMP/err")"
[ "$(head -1 "$TMP/work.md")" = "## Qué y por qué" ] && ok || ko "work opens with Qué y por qué"
for s in "## Qué y por qué" "## Verificación" "## Riesgo" "## Commits" "## Ficheros" "## Merge method"; do
  grep -qF "$s" "$TMP/work.md" && ok || ko "work has $s"
done
grep -q -- "- \[x\] Squash" "$TMP/work.md" && ok || ko "work ticks Squash"
grep -q "… [0-9]* líneas más" "$TMP/work.md" && ok || ko "the file list is cut at 40 lines" "$(sed -n '/## Ficheros/,$p' "$TMP/work.md")"
python3 -c "print('x' * 601)" > "$TMP/long"
body --base develop --mode work --summary-file "$TMP/long" --verify-file "$TMP/verify" >/dev/null; [ $? -eq 2 ] && ok || ko "a summary over 600 characters is refused"
: > "$TMP/empty"
body --base develop --mode work --summary-file "$TMP/summary" --verify-file "$TMP/empty" >/dev/null; [ $? -eq 2 ] && ok || ko "an empty verification is refused"
printf '{"label": "riesgo:0", "review": "none", "reasons": [{"class": 0, "why": "documentation", "paths": ["docs/f1.md"]}]}' > "$TMP/risk.json"
body --base develop --mode work --summary-file "$TMP/summary" --verify-file "$TMP/verify" --risk-json "$TMP/risk.json" > "$TMP/w2.md"
grep -q '`riesgo:0` · revisión: none' "$TMP/w2.md" && ok || ko "the risk section renders risk-class's output"

# human
body --base develop --mode human --summary-file "$TMP/summary" --verify-file "$TMP/verify" --why-file "$TMP/why" --repo acme/proyecto --pr 7 > "$TMP/human.md"; rc=$?
[ $rc -eq 0 ] && ok || ko "human renders (rc $rc)" "$(cat "$TMP/err")"
[ "$(head -1 "$TMP/human.md")" = "$(cat "$TMP/why")" ] && ok || ko "human: the reason a person is needed comes first" "$(head -3 "$TMP/human.md")"
sed -n '1,/^## /p' "$TMP/human.md" | grep -qx "gh pr merge 7 --repo acme/proyecto --squash" && ok || ko "human: the squash command of this PR, before any section"
grep -q "^## Qué y por qué" "$TMP/human.md" && ok || ko "human: then the work sections"
body --base develop --mode human --summary-file "$TMP/summary" --verify-file "$TMP/verify" --repo acme/proyecto --pr 7 >/dev/null; [ $? -eq 2 ] && ok || ko "human without --why-file is refused"
body --base develop --mode human --summary-file "$TMP/summary" --verify-file "$TMP/verify" --why-file "$TMP/why" > "$TMP/h0.md"; rc=$?
[ $rc -eq 0 ] && ! grep -q "gh pr merge" "$TMP/h0.md" && ok || ko "phase one (no --pr) renders without a command"

# promotion
g checkout -q develop
body --base main --head develop --mode promotion --repo acme/proyecto --pr 7 > "$TMP/promo.md"; rc=$?
[ $rc -eq 0 ] && ok || ko "promotion renders without a text (rc $rc)" "$(cat "$TMP/err")"
sed -n '1,/^## /p' "$TMP/promo.md" | grep -qx "gh pr merge 7 --repo acme/proyecto --merge" && ok || ko "promotion: the merge-commit command first" "$(cat "$TMP/promo.md")"
grep -qx -- "- #12 feat: change 12" "$TMP/promo.md" && grep -qx -- "- #13 feat: change 13" "$TMP/promo.md" && ok || ko "promotion lists the PRs of the range" "$(cat "$TMP/promo.md")"
grep -q -- "- \[x\] Merge commit" "$TMP/promo.md" && ok || ko "promotion ticks Merge commit"
body --base main --head develop --mode promotion --why-file "$TMP/why" --repo acme/proyecto --pr 7 > "$TMP/p2.md"
[ "$(head -1 "$TMP/p2.md")" = "$(cat "$TMP/why")" ] && ok || ko "promotion: the optional text comes first"

# usage
body --mode work >/dev/null; [ $? -eq 2 ] && ok || ko "--base is required"
body --base develop --mode work --pr 7 --summary-file "$TMP/summary" --verify-file "$TMP/verify" >/dev/null; [ $? -eq 2 ] && ok || ko "--pr without --repo"
timeout 5 "$PB" --base >/dev/null 2>&1; [ $? -eq 2 ] && ok || ko "--base without a value is exit 2 at once"

echo "pr-body: $pass/$((pass + fail)) cases pass"
rc=0; [ "$fail" -eq 0 ] || rc=1
if [ -z "${SUT_ROOT:-}" ] && [ -z "${SKIP_MUTANTS:-}" ]; then
  echo "== mutants (each one MUST die) =="
  m=0; k=0
  mutant() { # <why> <old> <new>
    local d; d="$(mktemp -d)"; cp -r "$HERE/../pr-body" "$d/"
    if ! python3 - "$d/pr-body/pr_body.py" "$2" "$3" <<'PY'
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
if old not in s:
    sys.exit(1)
open(p, "w").write(s.replace(old, new, 1))
PY
    then echo "  FAIL mutant «$1»: text no longer matches"; rc=1; rm -rf "$d"; return; fi
    m=$((m + 1))
    if SUT_ROOT="$d" FAIL_FAST=1 bash "$HERE/pr-body.test.sh" >/dev/null 2>&1; then echo "  FAIL mutant «$1» SURVIVES"; rc=1; else k=$((k + 1)); echo "  ok   mutant «$1» dies"; fi
    rm -rf "$d"
  }
  mutant "the reason goes after the technical part" 'parts += work_sections(repo_dir, base, head, summary, verify, risk)' 'parts[0:0] = work_sections(repo_dir, base, head, summary, verify, risk)'
  mutant "a promotion by squash" '"gh pr merge %s --repo %s --merge"' '"gh pr merge %s --repo %s --squash"'
  mutant "no merge command for a person" '"gh pr merge %s --repo %s --squash" % (a["pr"], a["repo"])' '""'
  mutant "the reason not required" 'merge_block(read(a["why_file"], "why"), cmd)' 'merge_block(read(a["why_file"], "why", required=False), cmd)'
  echo "mutants: $k/$m killed"
fi
exit $rc
