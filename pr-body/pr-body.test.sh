#!/usr/bin/env bash
# pr-body.test.sh — renders every mode from a throwaway git repo and passes each body through the
# REAL check-pr-tldr (`check.sh --body`), so "the body the script writes passes the linter" is
# proven, not assumed. Then mutates pr_body.py and requires a failure.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${SUT_ROOT:-$HERE/..}"
PB="$ROOT/pr-body/pr-body.sh"
CHECK="$ROOT/check-pr-tldr/check.sh"
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
cat > "$TMP/tldr-human" <<'MD'
**Qué cambia para ti:** la documentación pasa a una carpeta propia y el índice la encuentra sola; para los usuarios no cambia nada y no tienes que hacer nada después de mergear.

**Qué puede salir mal y cómo se deshace:** un enlace viejo podría quedar roto; se deshace revirtiendo esta PR.

**Qué NO se ha comprobado:** los enlaces desde fuera del repositorio.
MD
cat > "$TMP/tldr-promo" <<'MD'
**Qué notarán los usuarios:** dos cambios pequeños que ya estaban probados en la rama de integración; nada que tengan que hacer.

**Qué puede salir mal y cómo se deshace:** si algo fallara, se revierte el merge de la promoción y se vuelve a la versión anterior.

**Decisiones tuyas que van dentro:** ninguna.

**Qué NO se ha comprobado:** el comportamiento en los repositorios que lo consumen, hasta que suban de versión.
MD
body() { (cd "$R" && "$PB" "$@" --repo-dir "$R" 2> "$TMP/err"); }
judge() { # judge <file> <labels> [promo]
  local extra=()
  [ "${3:-}" = promo ] && extra=(--promotion --base-ref main --head-ref develop)
  bash "$CHECK" --body "$1" --pr 7 --repo acme/proyecto --labels "$2" "${extra[@]}" 2>&1
}

# work
body --base develop --mode work --summary-file "$TMP/summary" --verify-file "$TMP/verify" > "$TMP/work.md"; rc=$?
[ $rc -eq 0 ] && ok || ko "work renders (rc $rc)" "$(cat "$TMP/err")"
grep -q "^## TL;DR" "$TMP/work.md" && ko "work has no TL;DR (only where a person decides)" || ok
for s in "## Qué y por qué" "## Verificación" "## Riesgo" "## Commits" "## Ficheros" "## Merge method"; do
  grep -qF "$s" "$TMP/work.md" && ok || ko "work has $s"
done
grep -q -- "- \[x\] Squash" "$TMP/work.md" && ok || ko "work ticks Squash"
grep -q "… [0-9]* líneas más" "$TMP/work.md" && ok || ko "the file list is cut at 40 lines" "$(sed -n '/## Ficheros/,$p' "$TMP/work.md")"
out="$(judge "$TMP/work.md" "")"; [ $? -eq 0 ] && grep -q "no se juzga" <<<"$out" && ok || ko "work is not judged by check-pr-tldr" "$out"
python3 -c "print('x' * 601)" > "$TMP/long"
body --base develop --mode work --summary-file "$TMP/long" --verify-file "$TMP/verify" >/dev/null; [ $? -eq 2 ] && ok || ko "a summary over 600 characters is refused"
: > "$TMP/empty"
body --base develop --mode work --summary-file "$TMP/summary" --verify-file "$TMP/empty" >/dev/null; [ $? -eq 2 ] && ok || ko "an empty verification is refused"
printf '{"label": "riesgo:0", "review": "none", "reasons": [{"class": 0, "why": "documentation", "paths": ["docs/f1.md"]}]}' > "$TMP/risk.json"
body --base develop --mode work --summary-file "$TMP/summary" --verify-file "$TMP/verify" --risk-json "$TMP/risk.json" > "$TMP/w2.md"
grep -q '`riesgo:0` · revisión: none' "$TMP/w2.md" && ok || ko "the risk section renders risk-class's output"

# human
body --base develop --mode human --summary-file "$TMP/summary" --verify-file "$TMP/verify" --tldr-file "$TMP/tldr-human" --repo acme/proyecto --pr 7 > "$TMP/human.md"; rc=$?
[ $rc -eq 0 ] && ok || ko "human renders and passes its own check (rc $rc)" "$(cat "$TMP/err")"
[ "$(grep -m1 '^## ' "$TMP/human.md")" = "## TL;DR" ] && ok || ko "human: TL;DR first"
out="$(judge "$TMP/human.md" revision-humana)"; [ $? -eq 0 ] && ok || ko "human passes check-pr-tldr" "$out"
grep -qx "gh pr merge 7 --repo acme/proyecto --squash" "$TMP/human.md" && ok || ko "human: the squash command of this PR"
printf 'Poca cosa.\n' > "$TMP/tldr-short"
body --base develop --mode human --summary-file "$TMP/summary" --verify-file "$TMP/verify" --tldr-file "$TMP/tldr-short" --repo acme/proyecto --pr 7 >/dev/null; [ $? -eq 1 ] && ok || ko "a TL;DR that fails the linter is exit 1"
body --base develop --mode human --summary-file "$TMP/summary" --verify-file "$TMP/verify" --tldr-file "$TMP/tldr-human" > "$TMP/h0.md"; rc=$?
[ $rc -eq 0 ] && ! grep -q "gh pr merge" "$TMP/h0.md" && ok || ko "phase one (no --pr) renders without a command"

# promotion
g checkout -q develop
body --base main --head develop --mode promotion --tldr-file "$TMP/tldr-promo" --repo acme/proyecto --pr 7 > "$TMP/promo.md"; rc=$?
[ $rc -eq 0 ] && ok || ko "promotion renders and passes --promotion (rc $rc)" "$(cat "$TMP/err")"
out="$(judge "$TMP/promo.md" "" promo)"; [ $? -eq 0 ] && ok || ko "promotion passes check-pr-tldr --promotion" "$out"
grep -qx -- "- #12 feat: change 12" "$TMP/promo.md" && grep -qx -- "- #13 feat: change 13" "$TMP/promo.md" && ok || ko "promotion lists the PRs of the range" "$(cat "$TMP/promo.md")"
grep -q -- "- \[x\] Merge commit" "$TMP/promo.md" && ok || ko "promotion ticks Merge commit"
grep -v "Qué NO se ha comprobado" "$TMP/tldr-promo" > "$TMP/tldr-3"
body --base main --head develop --mode promotion --tldr-file "$TMP/tldr-3" --repo acme/proyecto --pr 7 >/dev/null; [ $? -eq 2 ] && ok || ko "a promotion TL;DR without the four fields is refused"

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
    local d; d="$(mktemp -d)"; cp -r "$HERE/../pr-body" "$HERE/../check-pr-tldr" "$d/"
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
  mutant "the TL;DR goes after the technical part" 'parts += work_sections(repo_dir, base, head, summary, verify, risk)' 'parts[0:0] = work_sections(repo_dir, base, head, summary, verify, risk)'
  mutant "a promotion by squash" '"gh pr merge %s --repo %s --merge"' '"gh pr merge %s --repo %s --squash"'
  mutant "no merge command for a person" '"\n\n**Tu «sí»** (en tu PC):\n\n```bash\ngh pr merge %s --repo %s --squash\n```" % (a["pr"], a["repo"])' '""'
  mutant "a TL;DR in the work mode" '        if mode == "human":' '        if mode in ("human", "work"):'
  mutant "the linter check skipped" '        if rc != 0:' '        if False:'
  echo "mutants: $k/$m killed"
fi
exit $rc
