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
# Citar la regla no es incumplirla: lo entrecomillado no cuenta. Salio con la primera PR que uso
# este control — explicaba la regla y el control la denuncio por nombrarla.
caso 0 "nombra «ver abajo» entre comillas, como ejemplo" 's/si el aviso fallara/que el resumen no diga «ver abajo»; si el aviso fallara/'

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


# --- modo promocion (--promotion): las reglas del resumen de release, una sola implementacion ---
promo() { cat <<'MD'
## TL;DR

**Qué notarán los usuarios:** llegan las acciones para mergear solo lo que no necesita revisión, en seco por defecto; quien no las adopte no nota nada.

**Qué puede salir mal y cómo se deshace:** un repositorio que las adopte podría ver comentarios de más en sus PRs; se apaga desactivando su workflow.

**Decisiones tuyas que van dentro:** ninguna nueva.

**Qué NO se ha comprobado:** el modo real, que necesita la App de merge.

```bash
gh pr merge 42 --repo acme/proyecto --merge
```

## PRs de esta promoción

- #12 feat: algo (`x.sh`)
MD
}
pcaso() { # pcaso <esperado> <etiqueta> <sed|""> [base] [head] [flags] [labels]
  local want="$1" label="$2" expr="$3" base="${4:-main}" head="${5:-develop}" flags="${6:---promotion}" labels="${7:-}" out rc
  if [ -n "$expr" ]; then promo | sed -E "$expr" > "$TMP/p.md"; else promo > "$TMP/p.md"; fi
  # shellcheck disable=SC2086
  out="$(bash "$CHECK" --body "$TMP/p.md" --pr 42 --repo acme/proyecto --labels "$labels" --base-ref "$base" --head-ref "$head" $flags 2>&1)"; rc=$?
  if [ "$rc" -eq "$want" ]; then pass=$((pass + 1)); return 0; fi
  fail=$((fail + 1)); printf 'FAIL  promocion: %s (esperaba exit %s, salio %s)\n%s\n' "$label" "$want" "$rc" "$out"
}
pcaso 0 "promocion completa, sin marca: se juzga y pasa" ""
pcaso 0 "sin --promotion, una promocion sin marca no se juzga (como hasta hoy)" 's/^\*\*Qué NO se ha comprobado.*//' main develop " "
pcaso 0 "con --promotion, una PR que no es promocion y sin marca no se juzga" 's/^\*\*Qué NO se ha comprobado.*//' develop feat/x
pcaso 1 "falta un campo" '/^\*\*Qué NO se ha comprobado/d'
pcaso 1 "campo con el texto de la plantilla" 's/^(\*\*Decisiones tuyas que van dentro:\*\*).*/\1 <qué decides>/'
pcaso 1 "codigo en linea en el TL;DR" 's/ninguna nueva\./ninguna nueva salvo `mode: live`./'
pcaso 1 "una ruta en el TL;DR" 's/ninguna nueva\./ninguna nueva salvo lo de scripts\/x.sh./'
pcaso 1 "una promocion por squash" 's/--merge$/--squash/'
pcaso 1 "el comando de otra PR" 's/gh pr merge 42/gh pr merge 43/'
pcaso 1 "sin comando en un bloque bash" 's/^```bash$/```text/'
pcaso 1 "el TL;DR no va primero" '1i ## Contexto\n\nAntes.\n'
pcaso 0 "codigo y rutas FUERA del TL;DR no cuentan" ""
# una PR marcada que no es promocion se sigue juzgando con las seis clases y nada mas: el codigo en
# linea en su TL;DR sigue permitido (el desacuerdo entre los dos linters se resuelve por modo)
bueno | sed -E 's/no se pierde trabajo/no se pierde trabajo (`x`)/' > "$TMP/nm.md"
bash "$CHECK" --body "$TMP/nm.md" --pr 42 --repo acme/proyecto --labels revision-humana --base-ref develop --head-ref feat/x --promotion >/dev/null 2>&1
[ $? -eq 0 ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL  una PR marcada que no es promocion no debe heredar las reglas de release"; }
msg="$(promo | sed -E 's/--merge$/--squash/' > "$TMP/sq.md"; bash "$CHECK" --body "$TMP/sq.md" --pr 42 --repo acme/proyecto --labels "" --base-ref main --head-ref develop --promotion 2>&1)"
case "$msg" in *"exactamente 'gh pr merge <n> --repo <owner>/<name> --merge'"*) pass=$((pass + 1)) ;; *) fail=$((fail + 1)); echo "FAIL  squash: el motivo no lo explica";; esac
bash "$CHECK" --body "$TMP/p.md" --pr 42 --repo acme/proyecto --labels >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL  --labels sin valor debe ser exit 2 (y no colgarse), salio $rc"; }
# camino de red: base/head leidos de la API
cat > "$TMP/bin/gh-promo" <<'STUB'
#!/usr/bin/env bash
python3 - "$@" <<'PY'
import json, os
body = open(os.environ["BODY_FIXTURE"], encoding="utf-8").read()
print(json.dumps({"body": body, "labels": [], "base": {"ref": "main"}, "head": {"ref": "develop"}}))
PY
STUB
chmod +x "$TMP/bin/gh-promo"
promo | sed -E 's/--merge$/--squash/' > "$TMP/net.md"
BODY_FIXTURE="$TMP/net.md" GH_API="$TMP/bin/gh-promo" bash "$CHECK" --repo acme/proyecto --pr 42 --promotion >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL  red: promocion leida de la API debe juzgarse (exit 1), salio $rc"; }
BODY_FIXTURE="$TMP/net.md" GH_API="$TMP/bin/gh-promo" bash "$CHECK" --repo acme/proyecto --pr 42 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL  red: sin --promotion no cambia nada, salio $rc"; }

echo "----------------------------------------"
[ "$fail" -eq 0 ] && { echo "OK: $pass/$((pass + fail)) casos pasan"; exit 0; }
echo "FALLOS: $fail/$((pass + fail))"; exit 1
