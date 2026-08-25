#!/usr/bin/env bash
# check.test.sh — dispara `check.sh` contra las seis clases de violacion y sus contrarias.
#
# POR DISPARO, NUNCA POR PRESENCIA. Cada caso trae su pareja: un pin que debe pasar y uno que debe
# fallar. Sin las dos mitades, "no denego" no se distingue de "dejo de mirar".
#
# `gh api` esta simulado a traves de la variable `GH_API`, que el script respeta a proposito. Las
# respuestas salen de ficheros, asi que cada caso puede describir un aguas-arriba a su gusto sin
# tocar la red — incluido el caso que no se puede provocar de verdad: que la API no responda.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$HERE/check.sh"
[ -f "$CHECK" ] || { echo "no encuentro $CHECK"; exit 1; }

LAB="$(mktemp -d)"
trap 'rm -rf "$LAB"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; }

SHA_A=1111111111111111111111111111111111111111
SHA_B=2222222222222222222222222222222222222222
SHA_TAGOBJ=3333333333333333333333333333333333333333

# --- `gh api` simulado -------------------------------------------------------
# Responde desde $FIX segun la ruta pedida. Un fichero ausente = respuesta vacia, que es como se
# simula un 404 o una API caida.
mkdir -p "$LAB/bin"
cat > "$LAB/bin/fakegh" <<'GHEOF'
#!/usr/bin/env bash
# uso: fakegh api <ruta> [--jq <filtro>]
ruta="$2"
clave=$(printf '%s' "$ruta" | tr '/' '_')
f="$FIX/$clave.json"
[ -f "$f" ] || exit 1
if [ "${3:-}" = "--jq" ]; then jq -r "$4" < "$f"; else cat "$f"; fi
GHEOF
chmod +x "$LAB/bin/fakegh"

# escribe la respuesta de matching-refs para un tag dado
refs() {   # refs <dir> <tag> <json-array>
  printf '%s' "$3" > "$1/fix/repos_acme_act_git_matching-refs_tags_$2.json"
}

# monta un repo sintetico con UNA linea uses:
monta() {  # monta <dir> <linea-uses>
  local R="$1"
  mkdir -p "$R/.github/workflows" "$R/fix"
  printf 'jobs:\n  x:\n    steps:\n      - uses: %s\n' "$2" > "$R/.github/workflows/w.yml"
  # el repo existe, para poder distinguir "tag inexistente" de "API caida"
  printf '{"name":"act"}\n' > "$R/fix/repos_acme_act.json"
}

# corre <etiqueta> <exit-esperado> <linea-uses> [<fixturizador>] [<patron-obligatorio>]
#
# El quinto argumento no es adorno. Sin el, un caso "esperaba 1 y salio 1" pasa aunque el 1 venga
# de OTRA regla — y entonces el mutante que desactiva la regla que el caso dice probar sobrevive,
# tapado por su vecina. Medido: los mutantes del SHA de 40 hex y del comentario ausente vivian
# exactamente asi, porque al seguir adelante caian en "ese tag no existe aguas arriba".
corre() {
  local etiqueta="$1" quiero="$2" linea="$3" fx="${4:-}" patron="${5:-}"
  local R="$LAB/c$((PASS+FAIL))"
  monta "$R" "$linea"
  [ -z "$fx" ] || "$fx" "$R"
  local out rc
  out=$(cd "$R" && GH_API="$LAB/bin/fakegh api" FIX="$R/fix" bash "$CHECK" .github/workflows 2>&1); rc=$?
  if [ "$rc" -ne "$quiero" ]; then
    bad "$etiqueta" "esperaba exit $quiero, salio $rc"; printf '%s\n' "$out" | sed 's/^/         /'; return
  fi
  if [ -n "$patron" ] && ! printf '%s' "$out" | grep -q "$patron"; then
    bad "$etiqueta" "exit correcto pero por otro motivo: no aparece '$patron'"; printf '%s\n' "$out" | sed 's/^/         /'; return
  fi
  ok "$etiqueta"
}

# fixturizadores
fx_exacto()   { refs "$1" 'v7.0.1' "[{\"ref\":\"refs/tags/v7.0.1\",\"object\":{\"sha\":\"$SHA_A\",\"type\":\"commit\"}}]"; }
fx_flotante() { refs "$1" 'v7' "[{\"ref\":\"refs/tags/v7\",\"object\":{\"sha\":\"$SHA_A\",\"type\":\"commit\"}},{\"ref\":\"refs/tags/v7.0.1\",\"object\":{\"sha\":\"$SHA_A\",\"type\":\"commit\"}}]"; }
fx_solo_mayor(){ refs "$1" 'v3' "[{\"ref\":\"refs/tags/v3\",\"object\":{\"sha\":\"$SHA_A\",\"type\":\"commit\"}}]"; }
fx_alias_otro(){ refs "$1" 'v7' "[{\"ref\":\"refs/tags/v7\",\"object\":{\"sha\":\"$SHA_A\",\"type\":\"commit\"}},{\"ref\":\"refs/tags/v7.0.2\",\"object\":{\"sha\":\"$SHA_B\",\"type\":\"commit\"}}]"; }
fx_deriva()   { refs "$1" 'v7.0.1' "[{\"ref\":\"refs/tags/v7.0.1\",\"object\":{\"sha\":\"$SHA_B\",\"type\":\"commit\"}}]"; }
fx_anotado()  { refs "$1" 'v7.0.1' "[{\"ref\":\"refs/tags/v7.0.1\",\"object\":{\"sha\":\"$SHA_TAGOBJ\",\"type\":\"tag\"}}]"
                printf '{"object":{"sha":"%s"}}\n' "$SHA_A" > "$1/fix/repos_acme_act_git_tags_$SHA_TAGOBJ.json"; }
fx_sin_repo() { rm -f "$1/fix/repos_acme_act.json"; }
# El tag NO existe: la API contesta `[]` con exit 0. Medido contra la API de verdad —
# `gh api repos/actions/checkout/git/matching-refs/tags/vNOEXISTE` devuelve `[]` y rc=0.
fx_tag_ausente() { refs "$1" 'v9.9.9' '[]'; }
# La llamada FALLA: el `gh` simulado sale con 1 cuando no hay fichero. El repo SI existe, que es
# justo la combinacion que fabricaba una violacion inventada.
fx_api_falla()   { rm -f "$1/fix/repos_acme_act_git_matching-refs_tags_v7.0.1.json"; }

echo "== 1. el ref tiene que ser un SHA de 40 hex =="
corre "pineado con un tag mutable -> 1" 1 "acme/act@v7.0.1 # v7.0.1" fx_exacto "no es un SHA de 40 hex"
corre "pineado con un SHA        -> 0" 0 "acme/act@$SHA_A # v7.0.1" fx_exacto

echo
echo "== 2. tiene que haber comentario =="
corre "SHA sin comentario -> 1" 1 "acme/act@$SHA_A" fx_exacto "SIN comentario"
corre "SHA con comentario -> 0" 0 "acme/act@$SHA_A # v7.0.1" fx_exacto

echo
echo "== 3. el tag tiene que existir aguas arriba =="
# `[]` con exit 0, que es lo que devuelve la API DE VERDAD cuando el tag no existe. Antes este
# caso no escribia fixture, o sea que el `gh` simulado salia con 1 — y eso NO es "el tag no
# existe", es "no se pudo preguntar". El doble ensenaba un contrato que la API no tiene, y con el
# puesto asi el caso de abajo (la API que falla) no se podia distinguir de este.
corre "el comentario nombra un tag inexistente -> 1" 1 "acme/act@$SHA_A # v9.9.9" fx_tag_ausente "NO existe aguas arriba"

# LA REGRESION DE HOY, y es la unica que separa un verificador util de uno que miente: si la
# llamada a `matching-refs` FALLA —limite de peticiones, red, 403 transitorio— eso es NO MEDIDO,
# no "ese tag no existe". Antes se deducia preguntando por OTRO endpoint (`repos/<owner>/<repo>`),
# y si ese si contestaba, salia una VIOLACION INVENTADA sobre un tag que existe.
corre "la API falla pero el repo existe -> 2 (NO MEDIDO), no 1" 2 "acme/act@$SHA_A # v7.0.1" fx_api_falla "no se pudo consultar la API"

echo
echo "== 4. deriva de etiqueta =="
corre "el tag apunta a OTRO sha -> 1" 1 "acme/act@$SHA_A # v7.0.1" fx_deriva "DERIVA"
corre "un tag ANOTADO se desreferencia y coincide -> 0" 0 "acme/act@$SHA_A # v7.0.1" fx_anotado

echo
echo "== 5. alias flotante: la clase que ningun verificador tenia =="
corre "'# v7' teniendo v7.0.1 el mismo SHA -> 1"          1 "acme/act@$SHA_A # v7" fx_flotante "FLOTANTE"
corre "'# v7.0.1' exacto -> 0"                            0 "acme/act@$SHA_A # v7.0.1" fx_exacto
# La mitad que evita el falso positivo: una accion que SOLO publica `vN` no tiene un nombre mas
# exacto que ofrecer, asi que `# v3` es lo mejor que existe y no se le puede reprochar.
corre "'# v3' cuando upstream solo publica vN -> 0"       0 "acme/act@$SHA_A # v3" fx_solo_mayor
# Y la otra mitad: existe un tag mas especifico pero apunta a OTRO commit, asi que no es un alias
# de este SHA. Sin esta distincion, cualquier accion con historial daria violacion.
corre "existe v7.0.2 pero de otro SHA -> 0"               0 "acme/act@$SHA_A # v7" fx_alias_otro

echo
echo "== 6. NO MEDIDO no es LIMPIO =="
corre "la API no responde -> 2, NO 0"                     2 "acme/act@$SHA_A # v7.0.1" fx_sin_repo
R="$LAB/vacio"; mkdir -p "$R/.github/workflows" "$R/fix"
out=$(cd "$R" && GH_API="$LAB/bin/fakegh api" FIX="$R/fix" bash "$CHECK" .github/workflows 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "un directorio SIN workflows -> 2, NO 0" || bad "un directorio SIN workflows -> 2, NO 0" "salio $rc"
out=$(cd "$LAB" && GH_API="$LAB/bin/fakegh api" bash "$CHECK" no/existe 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "un directorio inexistente -> 2" || bad "un directorio inexistente -> 2" "salio $rc"

echo
echo "== 7. lo que NO se audita, a proposito =="
corre "una action local ./x se ignora -> 0"      0 "./.github/actions/setup"
corre "una imagen docker:// se ignora -> 0"      0 "docker://alpine:3.20"

echo
echo "----------------------------------------"
printf 'check-action-pins: %s pasan, %s fallan (total %s).\n' "$PASS" "$FAIL" "$((PASS+FAIL))"
[ $((PASS+FAIL)) -ge 15 ] || { echo "::error::solo se ejecutaron $((PASS+FAIL)) comprobaciones, se esperaban >= 15"; exit 1; }
[ "$FAIL" -eq 0 ]
