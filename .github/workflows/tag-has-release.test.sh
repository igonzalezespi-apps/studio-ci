#!/usr/bin/env bash
# Self-test de `.github/workflows/tag-has-release.yml`.
#
# POR QUE EXISTE. El cuerpo de un `run:` no lo mira nadie hasta que corre, y corre el dia de una
# publicacion — el peor momento para descubrir un fallo. Ya paso en este repositorio con
# `check-action-pins` v0.6.0: salia con exit 1 y CERO salida justo en el unico caso para el que
# existia, porque el shell de un `run:` trae `-e` DESDE FUERA. Aqui la trampa es la misma forma:
# un `gh release view` que falla es el camino NORMAL, no un error.
#
# Esta suite EXTRAE el cuerpo real del `run:` del YAML —no lo copia— y lo ejecuta con el shell
# exacto de GitHub (`bash --noprofile --norc -e -o pipefail`) contra un `gh` de mentira que
# apunta lo que se le llama.
#
# Uso: bash .github/workflows/tag-has-release.test.sh
set -uo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
WF="$HERE/tag-has-release.yml"
[ -f "$WF" ] || { echo "FATAL: no encuentro $WF"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

extrae() { # extrae <yaml> <destino>
  python3 - "$1" "$2" <<'PY'
import sys, yaml, pathlib
d = yaml.safe_load(open(sys.argv[1]))
cuerpos = [p["run"] for j in d["jobs"].values() for p in j["steps"] if "run" in p]
assert len(cuerpos) == 1, f"esperaba UN paso `run:`, hay {len(cuerpos)}"
pathlib.Path(sys.argv[2]).write_text(cuerpos[0], encoding="utf-8")
PY
}

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 ${2:-}" in
  "release view")   exit "${VIEW_RC:-0}" ;;
  "release create") exit "${CREATE_RC:-0}" ;;
esac
exit 0
FAKE
chmod +x "$TMP/bin/gh"

PASS=0; FAIL=0

# corre <paso.sh> <etiqueta-del-caso> <view_rc> <create_rc> <exit-esperado> <debe-aparecer-en-el-log|-> <no-debe-aparecer|->
corre() {
  local paso=$1 caso=$2 vrc=$3 crc=$4 want=$5 debe=$6 nodebe=$7
  : > "$TMP/log"
  local got=0 out
  out=$(PATH="$TMP/bin:$PATH" GH_LOG="$TMP/log" VIEW_RC="$vrc" CREATE_RC="$crc" \
        TAG="v9.9.9" REPO="acme/proyecto" GH_TOKEN="x" \
        bash --noprofile --norc -e -o pipefail "$paso" 2>&1) || got=$?

  local ok=1 motivo=""
  [ "$got" -eq "$want" ] || { ok=0; motivo="esperaba exit $want, salio $got"; }
  if [ "$ok" = 1 ] && [ "$debe" != "-" ] && ! grep -qF -- "$debe" "$TMP/log"; then
    ok=0; motivo="no llamo a gh con «$debe» (llamadas: $(tr '\n' ';' < "$TMP/log"))"
  fi
  if [ "$ok" = 1 ] && [ "$nodebe" != "-" ] && grep -qF -- "$nodebe" "$TMP/log"; then
    ok=0; motivo="NO debia llamar a gh con «$nodebe» y lo hizo"
  fi
  if [ "$ok" = 1 ]; then
    PASS=$((PASS + 1)); printf '  ok   %s\n' "$caso"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL %s — %s\n' "$caso" "$motivo"
    printf '       salida: [%s]\n' "$(printf '%s' "$out" | tr '\n' '|')"
  fi
}

suite() { # suite <paso.sh>
  corre "$1" 'ya hay publicacion: no se toca nada'      0 0 0 'release view v9.9.9 --repo acme/proyecto' 'release create'
  corre "$1" 'etiqueta suelta: se crea la publicacion'  1 0 0 'release create v9.9.9 --repo acme/proyecto --verify-tag --generate-notes --title v9.9.9' -
  corre "$1" 'si la creacion falla, el paso se pone rojo' 1 1 1 'release create' -
}

echo "== el cuerpo real del run:, con el shell real de GitHub =="
extrae "$WF" "$TMP/paso.sh"
suite "$TMP/paso.sh"

# --- MUTACION: cada caso tiene que poder morir -------------------------------------------------
echo
echo "== mutantes (cada uno DEBE matar a alguien) =="
mutante() { # mutante <descripcion> <sed-expr>
  local desc=$1 expr=$2
  sed -E "$expr" "$TMP/paso.sh" > "$TMP/mut.sh"
  if cmp -s "$TMP/paso.sh" "$TMP/mut.sh"; then
    FAIL=$((FAIL + 1)); printf '  FAIL mutante «%s» no cambio nada (el patron ya no casa)\n' "$desc"; return
  fi
  local antes=$FAIL
  PASS_BAK=$PASS
  suite "$TMP/mut.sh" > /dev/null 2>&1
  if [ "$FAIL" -gt "$antes" ]; then
    printf '  ok   mutante «%s» MUERE\n' "$desc"
    FAIL=$antes; PASS=$((PASS_BAK + 1))
  else
    printf '  FAIL mutante «%s» SOBREVIVE: la suite no lo nota\n' "$desc"
    FAIL=$((antes + 1)); PASS=$PASS_BAK
  fi
}
mutante 'sin --verify-tag'            's/ --verify-tag//'
mutante 'no crea nada'                's/^(\s*)gh release create.*/\1true/'
mutante 'sigue tras encontrar la publicacion' 's/^(\s*)exit 0$/\1:/'

echo "----------------------------------------"
[ "$FAIL" -eq 0 ] && { echo "OK: $PASS/$((PASS + FAIL)) casos pasan"; exit 0; }
echo "FALLOS: $FAIL/$((PASS + FAIL))"; exit 1
