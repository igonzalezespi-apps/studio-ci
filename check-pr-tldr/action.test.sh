#!/usr/bin/env bash
# Self-test del ENVOLTORIO de la action, no de `check.sh`.
#
# POR QUE EXISTE. La suite del script no puede ver un fallo del YAML que lo llama, y ese fallo ya
# ocurrio una vez en este repo: `check-action-pins` v0.6.0 salia con exit 1 y CERO salida justo en
# el unico caso para el que existe, porque el shell de un `run:` trae `-e` desde fuera y
# `out=$(...)` mata el paso antes de imprimir nada.
#
# Esta suite EXTRAE el cuerpo real del `run:` de `action.yml` —no lo copia— y lo ejecuta con el
# mismo shell que usa GitHub (`bash --noprofile --norc -e -o pipefail`), contra un `check.sh`
# simulado que devuelve cada uno de los tres exits.
#
# Uso: check-pr-tldr/action.test.sh
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

# corre <exit-esperado> <etiqueta> <exit-del-check> <violaciones> <linea-que-debe-aparecer>
corre() {
  want=$1; label=$2; code=$3; viol=$4; esperado=$5
  rm -rf "$TMP/act"; mkdir -p "$TMP/act"
  cat > "$TMP/act/check.sh" <<FAKE
#!/usr/bin/env bash
echo "FAIL  1. falta la seccion '## TL;DR' (de mentira)"
echo "acme/proyecto#42 marcada, ${viol} violacion(es)."
exit ${code}
FAKE
  chmod +x "$TMP/act/check.sh"
  : > "$TMP/salida"; : > "$TMP/resumen"

  got=0
  out=$(GITHUB_ACTION_PATH="$TMP/act" PR_NUMBER=42 PR_REPO="acme/proyecto" FLAG_LABEL="revision-humana" \
        GITHUB_OUTPUT="$TMP/salida" GITHUB_STEP_SUMMARY="$TMP/resumen" \
        bash --noprofile --norc -e -o pipefail "$TMP/paso.sh" 2>&1) || got=$?

  local ok=1 motivo=""
  [ "$got" -eq "$want" ] || { ok=0; motivo="esperaba exit $want, salio $got"; }
  if [ "$ok" = "1" ] && ! printf '%s' "$out" | grep -qF "$esperado"; then
    ok=0; motivo="la salida NO contiene «$esperado»"
  fi
  if [ "$ok" = "1" ] && ! grep -q "violations=${viol}" "$TMP/salida"; then
    ok=0; motivo="no dejo violations=${viol} en GITHUB_OUTPUT (dice: $(tr -d '\n' < "$TMP/salida"))"
  fi
  if [ "$ok" = "1" ] && ! grep -q "check-pr-tldr" "$TMP/resumen"; then
    ok=0; motivo="no escribio el resumen del paso"
  fi
  if [ "$ok" = "1" ]; then
    PASS=$((PASS + 1)); printf '  ok   %s (exit %s, y lo dice)\n' "$label" "$got"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL %s — %s\n' "$label" "$motivo"
    printf '       salida: [%s]\n' "$(printf '%s' "$out" | tr '\n' '|')"
  fi
}

echo "== el envoltorio propaga el exit Y EL MOTIVO, con el shell real de GitHub =="
corre 0 'PR limpia (o sin la marca)'                 0 0 'marcada, 0 violacion(es)'
corre 1 'UNA VIOLACION: el caso que importa'         1 1 "falta la seccion '## TL;DR'"
corre 2 'no se pudo medir (API caida)'               2 0 "falta la seccion '## TL;DR'"

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && { echo "OK: $PASS/$((PASS + FAIL)) casos pasan"; exit 0; }
echo "FALLOS: $FAIL/$((PASS + FAIL))"; exit 1
