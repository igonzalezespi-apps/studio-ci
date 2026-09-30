#!/usr/bin/env bash
# Self-test del ENVOLTORIO de la action, no de `context-budget.sh`.
#
# POR QUE EXISTE. La suite del script no puede ver un fallo del YAML que lo llama, y ese fallo
# ya ocurrio en este repo: `check-action-pins` v0.6.0 salia con exit 1 y CERO salida justo en
# el unico caso para el que existe, porque el shell de un `run:` trae `-e` desde fuera y
# `out=$(...)` mata el paso antes de imprimir nada.
#
# Esta suite EXTRAE el cuerpo real del `run:` de `action.yml` —no lo copia— y lo ejecuta con el
# mismo shell que usa GitHub (`bash --noprofile --norc -e -o pipefail`), contra un
# `context-budget.sh` simulado que devuelve cada uno de los tres exits, y comprueba que los
# argumentos opcionales solo viajan cuando tienen valor.
#
# Uso: context-budget/action.test.sh
set -uo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
ACTION="$HERE/action.yml"
[ -f "$ACTION" ] || { echo "FATAL: no encuentro $ACTION"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

python3 - "$ACTION" "$TMP/paso.sh" <<'PY'
import sys, yaml, pathlib
d = yaml.safe_load(open(sys.argv[1]))
cuerpos = [p["run"] for p in d["runs"]["steps"] if "run" in p]
assert len(cuerpos) == 1, f"esperaba UN paso `run:`, hay {len(cuerpos)}"
pathlib.Path(sys.argv[2]).write_text(cuerpos[0], encoding="utf-8")
PY

PASS=0; FAIL=0

# corre <exit-esperado> <etiqueta> <exit-del-script> <violaciones> <avisos> <modo> <config> <en-args> <no-en-args>
corre() {
  local want=$1 label=$2 code=$3 viol=$4 warn=$5 mode=$6 config=$7 si=$8 no=$9
  rm -rf "$TMP/act"; mkdir -p "$TMP/act"
  cat > "$TMP/act/context-budget.sh" <<FAKE
#!/usr/bin/env bash
printf 'ARGS:'; printf ' [%s]' "\$@"; echo
echo "FAIL  [size] CLAUDE.md: 4.000 B > 3.000 B (+1.000)"
echo "::error file=CLAUDE.md,title=context-budget [size]::4.000 B > 3.000 B"
echo "context-budget: ${viol} violacion(es), ${warn} aviso(s) (modo enforce, 9 fichero(s) en el arbol)."
exit ${code}
FAKE
  : > "$TMP/salida"; : > "$TMP/resumen"

  local got=0 out
  out=$(GITHUB_ACTION_PATH="$TMP/act" CB_PATH="." CB_MODE="$mode" CB_CONFIG="$config" \
        CB_APPROVAL="presupuesto-contexto-aprobado" CB_LABELS="semver:none" \
        GITHUB_OUTPUT="$TMP/salida" GITHUB_STEP_SUMMARY="$TMP/resumen" \
        bash --noprofile --norc -e -o pipefail "$TMP/paso.sh" 2>&1) || got=$?

  local ok=1 motivo=""
  [ "$got" -eq "$want" ] || { ok=0; motivo="esperaba exit $want, salio $got"; }
  if [ "$ok" = "1" ] && ! printf '%s' "$out" | grep -qF "FAIL  [size] CLAUDE.md"; then
    ok=0; motivo="la salida NO trae el hallazgo"
  fi
  if [ "$ok" = "1" ] && ! grep -qx "violations=${viol}" "$TMP/salida"; then
    ok=0; motivo="no dejo violations=${viol} en GITHUB_OUTPUT (dice: $(tr '\n' ' ' < "$TMP/salida"))"
  fi
  if [ "$ok" = "1" ] && ! grep -qx "warnings=${warn}" "$TMP/salida"; then
    ok=0; motivo="no dejo warnings=${warn} en GITHUB_OUTPUT"
  fi
  if [ "$ok" = "1" ] && ! grep -q "### context-budget" "$TMP/resumen"; then
    ok=0; motivo="no escribio el resumen del paso"
  fi
  if [ "$ok" = "1" ] && grep -q '^::' "$TMP/resumen"; then
    ok=0; motivo="el resumen del paso lleva las lineas ::error (son para el runner, no para leer)"
  fi
  if [ "$ok" = "1" ] && [ -n "$si" ] && ! printf '%s' "$out" | grep -qF -- "$si"; then
    ok=0; motivo="los argumentos NO llevan «$si»"
  fi
  if [ "$ok" = "1" ] && [ -n "$no" ] && printf '%s' "$out" | grep '^ARGS:' | grep -qF -- "$no"; then
    ok=0; motivo="los argumentos llevan «$no» y no debian"
  fi
  if [ "$ok" = "1" ]; then
    PASS=$((PASS + 1)); printf '  ok   %s (exit %s)\n' "$label" "$got"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL %s — %s\n' "$label" "$motivo"
    printf '       salida: [%s]\n' "$(printf '%s' "$out" | tr '\n' '|')"
  fi
}

echo "== el envoltorio propaga el exit Y EL MOTIVO, con el shell real de GitHub =="
corre 0 'limpio (o solo avisos)'                  0 0 3 ""     ""  "[--annotations]" "[--mode]"
corre 1 'UNA VIOLACION: el caso que importa'      1 1 0 ""     ""  "[--labels] [semver:none]" "[--config]"
corre 2 'no se pudo medir'                        2 0 0 ""     ""  "[--approval-label] [presupuesto-contexto-aprobado]" ""
corre 1 'mode y config viajan cuando tienen valor' 1 1 0 "warn" "x.json" "[--mode] [warn]" ""
corre 1 'config viaja con su ruta'                1 1 0 ""     "cfg/cb.json" "[--config] [cfg/cb.json]" "[--mode]"

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && { echo "OK: $PASS/$((PASS + FAIL)) casos pasan"; exit 0; }
echo "FALLOS: $FAIL/$((PASS + FAIL))"; exit 1
