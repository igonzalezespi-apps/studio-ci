#!/usr/bin/env bash
# Self-test de `.github/workflows/renovate-heartbeat.yml`.
#
# Extrae el cuerpo REAL del `run:` y lo ejecuta con el shell de GitHub (`bash --noprofile --norc -e
# -o pipefail`) contra un `gh` de mentira que sirve respuestas de la API desde ficheros, aplica el
# `--jq` con jq de verdad y apunta cada llamada (y el cuerpo de cada PATCH). Sin red.
#
# Uso: bash .github/workflows/renovate-heartbeat.test.sh
set -uo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
WF="$HERE/renovate-heartbeat.yml"
[ -f "$WF" ] || { echo "FATAL: no encuentro $WF"; exit 1; }
command -v jq >/dev/null || { echo "FATAL: esta suite necesita jq"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

python3 - "$WF" "$TMP/paso.sh" <<'PY' || { echo "FATAL: no pude extraer el paso"; exit 1; }
import sys, yaml, pathlib
d = yaml.safe_load(open(sys.argv[1]))
cuerpos = [p["run"] for j in d["jobs"].values() for p in j["steps"] if p.get("id") == "heartbeat"]
assert len(cuerpos) == 1, f"esperaba UN paso heartbeat, hay {len(cuerpos)}"
pathlib.Path(sys.argv[2]).write_text(cuerpos[0], encoding="utf-8")
PY

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'FAKE'
#!/usr/bin/env bash
# gh de mentira: solo `gh api`. Endpoint -> fichero de $FIX; `--jq` con jq real.
printf '%s\n' "$*" >> "$GH_LOG"
[ "$1" = api ] || exit 9
shift
metodo=GET; jqf=""; campo=""; ep=""
while [ $# -gt 0 ]; do
  case "$1" in
    --paginate|--silent) shift ;;
    -X) metodo="$2"; shift 2 ;;
    --jq) jqf="$2"; shift 2 ;;
    -F) campo="$2"; shift 2 ;;
    *) ep="$1"; shift ;;
  esac
done
if [ -n "${FAIL_ON:-}" ] && [[ "$ep" == *"$FAIL_ON"* ]]; then echo "HTTP 403: Resource not accessible by integration" >&2; exit 1; fi
if [ "$metodo" = PATCH ]; then
  [ "${FAIL_PATCH:-0}" = 1 ] && { echo "HTTP 403: Resource not accessible by integration" >&2; exit 1; }
  n="${ep##*/}"; cp "${campo#body=@}" "$FIX/patched-$n.md"; exit 0
fi
case "$ep" in
  */issues\?*)        f="$FIX/issues.json" ;;
  */issues/*)         f="$FIX/issue-${ep##*/}.json" ;;
  */pulls\?*)         f="$FIX/pulls.json" ;;
  */commits/*/check-runs*) s="${ep#*/commits/}"; f="$FIX/checks-${s%%/*}.json" ;;
  *) echo "gh de mentira: endpoint desconocido $ep" >&2; exit 9 ;;
esac
[ -f "$f" ] || { case "$f" in *checks-*) echo '{"check_runs":[]}' > "$f" ;; *) echo "404 $ep" >&2; exit 1 ;; esac; }
if [ -n "$jqf" ]; then jq -r "$jqf" "$f"; else cat "$f"; fi
FAKE
chmod +x "$TMP/bin/gh"

hace() { date -u -d "-$1 hours" +%Y-%m-%dT%H:%M:%SZ; }
DASH_VACIO=' - [ ] <!-- manual job -->Check this box to trigger a request for Renovate to run again on this repository'
DASH_MARCADO=' - [x] <!-- manual job -->Check this box to trigger a request for Renovate to run again on this repository'

PASS=0; FAIL=0
N=0
# escenario: crea $FIX nuevo. Uso: escenario; luego issue/cuerpo/pr/checks
escenario() { N=$((N + 1)); FIX="$TMP/fix-$N"; mkdir -p "$FIX"; echo '[]' > "$FIX/issues.json"; echo '[]' > "$FIX/pulls.json"; }
issue() { # issue <num> <titulo> <updated_at> [<cuerpo>]
  jq --argjson n "$1" --arg t "$2" --arg u "$3" '. + [{number: $n, title: $t, updated_at: $u}]' "$FIX/issues.json" > "$FIX/i.tmp" && mv "$FIX/i.tmp" "$FIX/issues.json"
  jq -n --argjson n "$1" --arg b "${4:-}" '{number: $n, body: $b}' > "$FIX/issue-$1.json"
}
pr() { # pr <num> <sha> [<login>]
  jq --argjson n "$1" --arg s "$2" --arg l "${3:-renovate[bot]}" '. + [{number: $n, head: {sha: $s}, user: {login: $l}}]' "$FIX/pulls.json" > "$FIX/p.tmp" && mv "$FIX/p.tmp" "$FIX/pulls.json"
}
checks() { # checks <sha> <nombre:conclusion>...
  local s=$1; shift
  printf '%s\n' "$@" | jq -R 'split(":") | {name: .[0], conclusion: .[1]}' | jq -s '{check_runs: .}' > "$FIX/checks-$s.json"
}
# corre <caso> <exit> [VAR=valor...] -- <debe|-> <no-debe|->
corre() {
  local caso=$1 want=$2; shift 2
  local vars=()
  while [ "$1" != "--" ]; do vars+=("$1"); shift; done
  shift
  local debe=$1 nodebe=$2 out got=0
  : > "$FIX/gh.log"
  out="$(env PATH="$TMP/bin:$PATH" GH_LOG="$FIX/gh.log" FIX="$FIX" RUNNER_TEMP="$FIX" GITHUB_STEP_SUMMARY="$FIX/summary" \
        GH_TOKEN=x REPO=acme/app PING=true MAX_SILENCE_HOURS=48 STUCK_PRS=true \
        DASHBOARD_TITLE="Dependency Dashboard" BOT_LOGIN="renovate[bot]" "${vars[@]}" \
        bash --noprofile --norc -e -o pipefail "$TMP/paso.sh" 2>&1)" || got=$?
  local motivo=""
  [ "$got" -eq "$want" ] || motivo="esperaba exit $want, salio $got"
  if [ -z "$motivo" ] && [ "$debe" != "-" ] && ! grep -qF -- "$debe" <<< "$out"; then motivo="falta «$debe»"; fi
  if [ -z "$motivo" ] && [ "$nodebe" != "-" ] && grep -qF -- "$nodebe" <<< "$out"; then motivo="sobra «$nodebe»"; fi
  if [ -z "$motivo" ]; then PASS=$((PASS + 1)); printf '  ok   %s\n' "$caso"
  else FAIL=$((FAIL + 1)); printf '  FAIL %s — %s\n' "$caso" "$motivo"; printf '%s\n' "$out" | sed 's/^/       | /' | head -20; fi
}
parcheado() { [ -f "$FIX/patched-$1.md" ]; }
afirma() { # afirma <caso> <condicion...>
  local caso=$1; shift
  if "$@"; then PASS=$((PASS + 1)); printf '  ok   %s\n' "$caso"; else FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$caso"; fi
}

echo "== el ping =="
escenario; issue 3 "Dependency Dashboard" "$(hace 30)" "$(printf '## Pending Approval\n\n - [ ] <!-- approve-branch=x -->algo\n\n---\n\n%s\n' "$DASH_VACIO")"
corre "casilla vacia: Renovate contesto; se envia un ping nuevo" 0 -- "ping nuevo enviado en el dashboard #3" -
afirma "  ... el PATCH marca SOLO la casilla del ping" grep -qF '[x] <!-- manual job -->' "$FIX/patched-3.md"
afirma "  ... y deja intactas las demas casillas" grep -qF ' - [ ] <!-- approve-branch=x -->algo' "$FIX/patched-3.md"
afirma "  ... sin tocar nada mas del cuerpo" bash -c "diff <(sed 's/\[x\] <!-- manual job -->/[ ] <!-- manual job -->/' '$FIX/patched-3.md') <(jq -r .body '$FIX/issue-3.json')"

escenario; issue 3 "Dependency Dashboard" "$(hace 2)" "$DASH_MARCADO"
corre "casilla marcada hace 2 h: ping en curso, verde" 0 -- "ping en curso en el dashboard #3 desde hace 2 h" -
afirma "  ... y no se vuelve a marcar" bash -c "! test -f '$FIX/patched-3.md'"

escenario; issue 3 "Dependency Dashboard" "$(hace 60)" "$DASH_MARCADO"
corre "casilla marcada hace 60 h (umbral 48): Renovate no contesta, rojo" 1 -- "lleva 60 h sin respuesta" -
corre "el mismo caso con umbral 72: todavia verde" 0 MAX_SILENCE_HOURS=72 -- "ping en curso" -

escenario; issue 3 "Dependency Dashboard" "$(hace 30)" "$DASH_VACIO"
corre "ping desactivado (PR): solo lectura" 0 PING=false -- "ping desactivado" -
afirma "  ... sin PATCH" bash -c "! test -f '$FIX/patched-3.md'"
corre "PATCH rechazado: no medido (2), con el permiso que falta" 2 FAIL_PATCH=1 -- "hace falta issues: write" -

escenario; issue 3 "Dependency Dashboard" "$(hace 1)" "Sin casilla"
corre "dashboard sin casilla y ping pedido: no medido (2)" 2 -- "no tiene la casilla de re-ejecucion" -
corre "dashboard sin casilla y ping desactivado: aviso" 0 PING=false -- "::warning::el dashboard #3 no tiene la casilla" -

echo "== lo que Renovate declara =="
escenario
corre "sin dashboard: rojo" 1 -- "no hay una issue abierta 'Dependency Dashboard'" -
escenario; issue 3 "Dependency Dashboard" "$(hace 1)" "$DASH_VACIO"; issue 9 "Action Required: Fix Renovate Configuration" "$(hace 1)" "config rota"
corre "issue de configuracion rota: rojo" 1 -- "configuracion rota y no esta renovando nada: issue #9" -
escenario; issue 3 "Dependency Dashboard" "$(hace 1)" "$(printf '## Repository problems\n\nThese problems occurred while renovating this repository.\n\n - WARN: Cannot access vulnerability alerts. Please ensure permissions have been granted.\n\n## Detected\n\n%s\n' "$DASH_VACIO")"
corre "problemas declarados en el dashboard: aviso, no rojo" 0 -- "::warning::el dashboard #3 declara problemas: WARN: Cannot access vulnerability alerts" -
escenario; issue 7 "Dependency Dashboard" "$(hace 1)" "$DASH_VACIO"; issue 3 "Dependency Dashboard" "$(hace 1)" "$DASH_VACIO"
corre "dos dashboards: aviso y se usa el primero que devuelve la API (el mas reciente)" 0 -- "ping nuevo enviado en el dashboard #7" -
escenario; issue 3 "Mi panel" "$(hace 1)" "$DASH_VACIO"
corre "dependencyDashboardTitle propio" 0 DASHBOARD_TITLE="Mi panel" -- "dashboard #3" -

echo "== PRs atascadas =="
escenario; issue 3 "Dependency Dashboard" "$(hace 1)" "$DASH_MARCADO"
pr 12 aaa111; checks aaa111 "ci / test:success" "security / scan:cancelled"
pr 13 bbb222; checks bbb222 "ci / test:success" "security / scan:success"
pr 14 ccc333 "otra-persona"; checks ccc333 "security / scan:cancelled"
corre "PR del bot con un check cancelado en su cabeza: rojo" 1 -- "PR #12 de renovate[bot]: check(s) cancelado(s) en su cabeza (security / scan)" "PR #13"
corre "  ... y la PR de una persona no se mira" 1 -- "revisadas: 2" "PR #14"
corre "stuck-prs desactivado: no se listan PRs" 0 STUCK_PRS=false -- - "PR #12"
afirma "  ... ni una llamada a pulls" bash -c "! grep -q pulls '$FIX/gh.log'"
escenario; issue 3 "Dependency Dashboard" "$(hace 1)" "$DASH_MARCADO"; pr 12 aaa111; checks aaa111 "x:timed_out"
corre "timed_out tambien bloquea el automerge" 1 -- "cancelado(s) en su cabeza (x)" -

echo "== no medido nunca es verde =="
escenario; issue 3 "Dependency Dashboard" "$(hace 1)" "$DASH_MARCADO"; pr 12 aaa111
corre "sin permiso para listar issues: 2" 2 FAIL_ON=issues? -- "no pude listar las issues" -
corre "sin permiso para leer checks: 2" 2 FAIL_ON=check-runs -- "hace falta checks: read" -
corre "sin permiso para listar PRs: 2" 2 FAIL_ON=pulls -- "hace falta pull-requests: read" -
corre "max-silence-hours no numerico: 2" 2 MAX_SILENCE_HOURS=2d -- "no es un entero de horas" -

echo
echo "renovate-heartbeat.test.sh: $PASS ok, $FAIL fallos"
[ "$FAIL" -eq 0 ]
