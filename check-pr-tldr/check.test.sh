#!/usr/bin/env bash
# check.test.sh — dispara `check.sh` contra las seis clases de violacion y sus contrarias.
#
# POR DISPARO, NUNCA POR PRESENCIA, y cada caso con su pareja: un cuerpo que pasa y uno que falla
# por ESA regla. Sin las dos mitades, "no denego" no se distingue de "dejo de mirar".
#
# El cuerpo se pasa por `--body`, asi que la suite no toca la red. El camino de red tiene sus dos
# casos propios con `GH_API` simulado, incluido el que no se puede provocar de verdad: que la API
# no responda.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$HERE/check.sh"
[ -f "$CHECK" ] || { echo "no encuentro $CHECK"; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0

bueno() { cat <<'MD'
## TL;DR

**Que cambia para ti:** las sesiones dejan de avisar por dos sitios distintos y pasa a haber uno solo, el de siempre. Para los usuarios del producto no cambia nada, y nadie tiene que hacer nada despues de mergear.

**Que puede salir mal y como se deshace:** si el aviso fallara, no se pierde trabajo: se ve en la siguiente sesion. Revertir esta PR lo deja como estaba, en un minuto.

**Que NO se ha comprobado:** el comportamiento con la caja nueva, que todavia no existe.

**Tu «si»** (en tu PC, en Git Bash):

```bash
gh pr merge 42 --repo acme/proyecto --squash
```

## Lo tecnico

Detalle en `scripts/x.sh`, ADR-7, decision D12, issue #99.
MD
}

caso() { # caso <esperado> <etiqueta> <sed|""> [labels]
  local want="$1" label="$2" expr="$3" labels="${4:-revision-humana}" out rc
  if [ -n "$expr" ]; then bueno | sed -E "$expr" > "$TMP/b.md"; else bueno > "$TMP/b.md"; fi
  out="$(bash "$CHECK" --body "$TMP/b.md" --pr 42 --repo acme/proyecto --labels "$labels" 2>&1)"; rc=$?
  if [ "$rc" -eq "$want" ]; then pass=$((pass + 1)); return 0; fi
  fail=$((fail + 1)); printf 'FAIL  %s (esperaba exit %s, salio %s)\n%s\n' "$label" "$want" "$rc" "$out"
}

# --- el cuerpo correcto, y la PR sin marca ----------------------------------
caso 0 "cuerpo completo y marcado: pasa" ""
caso 0 "sin la marca: no se juzga" 's/^## TL;DR$/## Resumen/' "semver:none"
# la misma PR mal escrita, pero marcada -> falla. Es el par de la linea de arriba.
caso 1 "marcada y sin TL;DR: falla" 's/^## TL;DR$/## Resumen/'

# --- 2. el TL;DR no va primero ----------------------------------------------
caso 1 "TL;DR detras de otra seccion" '1i ## Contexto\n\nTexto previo.\n'

# --- 3. seccion vacia --------------------------------------------------------
caso 1 "TL;DR de un titular" 's/^\*\*Que cambia.*/**Que cambia para ti:** poco./; /^\*\*Que puede salir mal/d; /^\*\*Que NO se ha/d'

# --- 4. remite a otro sitio --------------------------------------------------
caso 1 "dice «ver abajo»" 's/nadie tiene que hacer nada despues de mergear/el detalle esta mas abajo/'
caso 0 "«abajo» fuera del TL;DR no cuenta" 's|Detalle en `scripts/x.sh`|Ver mas abajo, en `scripts/x.sh`|'

# --- 5. cita una fuente sin traerla ------------------------------------------
caso 1 "cita un ADR sin enlace ni linea" 's/si el aviso fallara/segun el ADR-7, si el aviso fallara/'
caso 0 "la misma cita CON enlace pasa" 's|si el aviso fallara|segun el ADR-7 (https://example.invalid/adr-7), si el aviso fallara|'
caso 1 "cita una decision vieja sin traerla" 's/si el aviso fallara/por la decision D12, si el aviso fallara/'

# --- 6. el comando de merge --------------------------------------------------
caso 1 "sin comando de merge" '/^gh pr merge/d'
# ...y con el MOTIVO correcto. Sin esta asercion, un guard que se rompiera al no encontrar el
# comando saldria distinto de 0 igualmente y el caso de arriba pasaria por accidente: medido, un
# mutante que borraba la comprobacion sobrevivia a la suite entera.
bueno | sed -E '/^gh pr merge/d' > "$TMP/nocmd.md"
msg="$(bash "$CHECK" --body "$TMP/nocmd.md" --pr 42 --repo acme/proyecto --labels revision-humana 2>&1)"
case "$msg" in
  *"no trae el comando de merge completo"*) pass=$((pass + 1)) ;;
  *) fail=$((fail + 1)); printf 'FAIL  sin comando: el motivo no lo explica :: %s\n' "$(printf '%s' "$msg" | tr '\n' ' ' | cut -c1-140)" ;;
esac
caso 1 "comando de OTRA PR" 's/gh pr merge 42/gh pr merge 43/'
caso 1 "comando de OTRO repo" 's|--repo acme/proyecto|--repo acme/otro|'
caso 0 "el mismo comando con otro metodo de merge pasa" 's/--squash/--merge/'

# --- la etiqueta es configurable ---------------------------------------------
bueno > "$TMP/label.md"
out="$(bash "$CHECK" --body "$TMP/label.md" --pr 42 --repo acme/proyecto --labels "revisar-humano" --label revisar-humano 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL  --label a medida: exit $rc"; fi

# --- camino de RED, con `gh api` simulado ------------------------------------
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh-ok" <<'STUB'
#!/usr/bin/env bash
python3 - "$@" <<'PY'
import json, sys
body = open(__import__("os").environ["BODY_FIXTURE"], encoding="utf-8").read()
print(json.dumps({"body": body, "labels": [{"name": "revision-humana"}]}))
PY
STUB
cat > "$TMP/bin/gh-ko" <<'STUB'
#!/usr/bin/env bash
echo "gh: Not Found (HTTP 404)" >&2; exit 1
STUB
chmod +x "$TMP/bin/gh-ok" "$TMP/bin/gh-ko"
bueno > "$TMP/red.md"
BODY_FIXTURE="$TMP/red.md" GH_API="$TMP/bin/gh-ok" bash "$CHECK" --repo acme/proyecto --pr 42 >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL  camino de red con cuerpo correcto: exit $rc"; fi
GH_API="$TMP/bin/gh-ko" bash "$CHECK" --repo acme/proyecto --pr 42 >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL  API caida debe ser exit 2 (no saber no es estar limpio), salio $rc"; fi

# --- usos invalidos ----------------------------------------------------------
bash "$CHECK" --pr 42 >/dev/null 2>&1; [ $? -eq 2 ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL  sin --repo debe ser exit 2"; }
bash "$CHECK" --repo acme/proyecto >/dev/null 2>&1; [ $? -eq 2 ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL  sin --pr debe ser exit 2"; }

echo "----------------------------------------"
[ "$fail" -eq 0 ] && { echo "OK: $pass/$((pass + fail)) casos pasan"; exit 0; }
echo "FALLOS: $fail/$((pass + fail))"; exit 1
