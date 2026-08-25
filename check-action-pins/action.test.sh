#!/usr/bin/env bash
# Self-test del ENVOLTORIO de la action, no de `check.sh`.
#
# POR QUE EXISTE. `check.test.sh` cubre el script con 16 casos y 9 mutantes, y aun asi la action
# publicada en v0.6.0 NO PODIA INFORMAR DE UNA VIOLACION: salia con exit 1 y CERO salida, que es el
# unico caso para el que existe. El fallo no estaba en el script — estaba en las dos lineas de
# `action.yml` que lo llaman.
#
# La causa: el shell por defecto de un `run:` es `bash --noprofile --norc -e -o pipefail {0}`.
# `-e` viene puesto DESDE FUERA, asi que `out=$(check.sh ...)` con salida distinta de 0 mata el
# paso antes del `printf` que imprime el hallazgo. Con 0 violaciones todo iba bien, que es por lo
# que se cablearon nueve repos limpios sin notarlo.
#
# ESTA SUITE EJECUTA EL CUERPO REAL de `action.yml` —extraido del fichero, no copiado— con el MISMO
# shell que usa GitHub, contra un `check.sh` simulado que devuelve cada uno de los tres exits.
#
# Uso: check-action-pins/action.test.sh
set -uo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
ACTION="$HERE/action.yml"
[ -f "$ACTION" ] || { echo "FATAL: no encuentro $ACTION"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

# El cuerpo del `run:` se SACA del YAML. Copiarlo aqui haria que la suite siguiera verde sobre una
# action rota, que es exactamente el fallo que esta suite existe para impedir.
python3 - "$ACTION" "$TMP/paso.sh" <<'PY'
import sys, yaml, pathlib
d = yaml.safe_load(open(sys.argv[1]))
pasos = d["runs"]["steps"]
cuerpos = [p["run"] for p in pasos if "run" in p]
assert len(cuerpos) == 1, f"esperaba UN paso `run:`, hay {len(cuerpos)}"
pathlib.Path(sys.argv[2]).write_text(cuerpos[0], encoding="utf-8")
PY

PASS=0; FAIL=0

# corre <exit-esperado> <etiqueta> <exit-del-check> <linea-que-debe-aparecer>
corre() {
  want=$1; label=$2; code=$3; esperado=$4
  rm -rf "$TMP/act"; mkdir -p "$TMP/act"
  cat > "$TMP/act/check.sh" <<FAKE
#!/usr/bin/env bash
echo "  ✖ un pin roto de mentira" >&2
echo "check-action-pins: 9 linea(s) \\\`uses:\\\`, 9 externa(s), $( [ "$code" = "1" ] && echo 1 || echo 0 ) violacion(es), 0 sin medir."
exit $code
FAKE
  chmod +x "$TMP/act/check.sh"
  : > "$TMP/salida"; : > "$TMP/resumen"

  got=0
  out=$(GITHUB_ACTION_PATH="$TMP/act" WF_DIR=".github/workflows" \
        GITHUB_OUTPUT="$TMP/salida" GITHUB_STEP_SUMMARY="$TMP/resumen" \
        bash --noprofile --norc -e -o pipefail "$TMP/paso.sh" 2>&1) || got=$?

  local ok=1
  [ "$got" -eq "$want" ] || { ok=0; motivo="esperaba exit $want, salio $got"; }
  if [ "$ok" = "1" ] && ! printf '%s' "$out" | grep -qF "$esperado"; then
    ok=0; motivo="la salida NO contiene «$esperado»"
  fi
  if [ "$ok" = "1" ]; then
    PASS=$((PASS + 1)); printf '  ok   %s (exit %s, y lo dice)\n' "$label" "$got"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL %s — %s\n' "$label" "$motivo"
    printf '       salida: [%s]\n' "$(printf '%s' "$out" | tr '\n' '|')"
  fi
}

echo "== el envoltorio propaga el exit Y EL MOTIVO, con el shell real de GitHub =="
corre 0 'todos los pins sanos'            0 'check-action-pins:'
corre 1 'UNA VIOLACION: el caso que estaba roto' 1 '✖ un pin roto de mentira'
corre 2 'no se pudo medir'                2 '✖ un pin roto de mentira'

echo "== y deja escrito el numero de violaciones para quien lo consuma =="
rm -rf "$TMP/act"; mkdir -p "$TMP/act"
cat > "$TMP/act/check.sh" <<'FAKE'
#!/usr/bin/env bash
echo "check-action-pins: 9 linea(s) `uses:`, 9 externa(s), 3 violacion(es), 0 sin medir."
exit 1
FAKE
chmod +x "$TMP/act/check.sh"
: > "$TMP/salida"; : > "$TMP/resumen"
GITHUB_ACTION_PATH="$TMP/act" WF_DIR=".github/workflows" \
  GITHUB_OUTPUT="$TMP/salida" GITHUB_STEP_SUMMARY="$TMP/resumen" \
  bash --noprofile --norc -e -o pipefail "$TMP/paso.sh" >/dev/null 2>&1
if grep -qx 'violations=3' "$TMP/salida"; then
  PASS=$((PASS + 1)); echo "  ok   violations=3 en GITHUB_OUTPUT"
else
  FAIL=$((FAIL + 1)); echo "  FAIL GITHUB_OUTPUT dice [$(cat "$TMP/salida" | tr '\n' '|')], esperaba violations=3"
fi
if grep -q 'check-action-pins' "$TMP/resumen"; then
  PASS=$((PASS + 1)); echo "  ok   el resumen del run lleva el informe"
else
  FAIL=$((FAIL + 1)); echo "  FAIL el resumen del run quedo vacio"
fi

echo
TOTAL=$((PASS + FAIL))
[ "$FAIL" -eq 0 ] && { echo "OK: $PASS/$TOTAL"; exit 0; }
echo "FALLOS: $FAIL de $TOTAL"; exit 1
