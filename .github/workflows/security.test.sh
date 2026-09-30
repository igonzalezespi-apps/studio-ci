#!/usr/bin/env bash
# Self-test de `.github/workflows/security.yml`.
#
# Extrae el cuerpo REAL de cada `run:` del YAML (por el `id` del paso; no lo copia) y lo ejecuta con
# el shell exacto de GitHub (`bash --noprofile --norc -e -o pipefail`) contra repos git de prueba y
# binarios de mentira (`gitleaks`, `pnpm`, `npm`, `curl`, `uname`) que apuntan como se les llama.
# Sin red. La concurrencia se prueba aparte, en `concurrency.test.sh`.
#
# Uso: bash .github/workflows/security.test.sh
set -uo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
WF="$HERE/security.yml"
[ -f "$WF" ] || { echo "FATAL: no encuentro $WF"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

extrae() { # extrae <id-del-paso> <destino>
  python3 - "$WF" "$1" "$2" <<'PY'
import sys, yaml, pathlib
d = yaml.safe_load(open(sys.argv[1]))
cuerpos = [p["run"] for j in d["jobs"].values() for p in j["steps"] if p.get("id") == sys.argv[2] and "run" in p]
assert len(cuerpos) == 1, f"esperaba UN paso con id {sys.argv[2]}, hay {len(cuerpos)}"
pathlib.Path(sys.argv[3]).write_text(cuerpos[0], encoding="utf-8")
PY
}
for paso in caller-guard gitleaks-install secrets audit; do
  extrae "$paso" "$TMP/$paso.sh" || { echo "FATAL: no pude extraer el paso $paso"; exit 1; }
done

PASS=0; FAIL=0
# veredicto <caso> <exit-real> <exit-esperado> <salida> [<debe-contener>|-] [<no-debe-contener>|-]
veredicto() {
  local caso=$1 got=$2 want=$3 out=$4 debe=${5:--} nodebe=${6:--} motivo=""
  [ "$got" -eq "$want" ] || motivo="esperaba exit $want, salio $got"
  if [ -z "$motivo" ] && [ "$debe" != "-" ] && ! grep -qF -- "$debe" <<< "$out"; then motivo="falta «$debe»"; fi
  if [ -z "$motivo" ] && [ "$nodebe" != "-" ] && grep -qF -- "$nodebe" <<< "$out"; then motivo="sobra «$nodebe»"; fi
  if [ -z "$motivo" ]; then
    PASS=$((PASS + 1)); printf '  ok   %s\n' "$caso"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL %s — %s\n' "$caso" "$motivo"
    printf '%s\n' "$out" | sed 's/^/       | /' | head -30
  fi
}

gitq() { git -c user.name=t -c user.email=t@example.invalid -c init.defaultBranch=develop -c commit.gpgsign=false "$@"; }

# ── caller-guard ─────────────────────────────────────────────────────────────────────────────────
echo "== caller-guard: el workflow que llama no mete etiquetas en un grupo que cancela =="
guard() { # guard <caso> <exit> <yaml-del-llamador> [debe] [no-debe]
  local d="$TMP/guard-$PASS-$FAIL" out rc=0
  mkdir -p "$d/.github/workflows"
  printf '%s\n' "$3" > "$d/.github/workflows/sec.yml"
  out="$(cd "$d" && WORKFLOW_REF="acme/app/.github/workflows/sec.yml@refs/pull/1/merge" REPO="acme/app" \
        bash --noprofile --norc -e -o pipefail "$TMP/caller-guard.sh" 2>&1)" || rc=$?
  veredicto "$1" "$rc" "$2" "$out" "${4:--}" "${5:--}"
}
USO='    uses: igonzalezespi-apps/studio-ci/.github/workflows/security.yml@0123456789abcdef0123456789abcdef01234567 # v0.9.0'
guard "tipos por defecto + concurrency que cancela: permitido" 0 "on:
  pull_request:
concurrency:
  group: x-\${{ github.ref }}
  cancel-in-progress: true
jobs:
  security:
$USO" "solo escucha eventos de codigo"
guard "labeled + concurrency de workflow: rechazado" 1 "on:
  pull_request:
    types: [opened, synchronize, labeled]
concurrency:
  group: x-\${{ github.ref }}
  cancel-in-progress: true
jobs:
  security:
$USO" "::error file=.github/workflows/sec.yml::"
guard "labeled + concurrency que NO cancela: tambien rechazado (el pendiente se cancela)" 1 "on:
  pull_request:
    types: [opened, labeled]
concurrency:
  group: x
  cancel-in-progress: false
jobs:
  security:
$USO" "escucha labeled"
guard "unlabeled + concurrency en el job que llama: rechazado" 1 "on:
  pull_request:
    types: [opened, unlabeled]
jobs:
  security:
    concurrency: x
$USO" "el job \`security\`"
guard "types como cadena (edited) + concurrency: rechazado" 1 "on:
  pull_request:
    types: edited
concurrency: x
jobs:
  security:
$USO" "escucha edited"
guard "labeled sin concurrency propio: permitido" 0 "on:
  pull_request:
    types: [opened, synchronize, labeled]
jobs:
  security:
$USO" "sin \`concurrency\` propio"
guard "labeled + concurrency en OTRO job: permitido" 0 "on:
  pull_request:
    types: [opened, labeled]
jobs:
  otro:
    concurrency: x
    runs-on: ubuntu-latest
    steps: []
  security:
$USO"
guard "on como lista [push, pull_request] + concurrency: permitido" 0 "on: [push, pull_request]
concurrency: x
jobs:
  security:
$USO"
guard "uses local (./.github/workflows/security.yml) tambien se reconoce" 1 "on:
  pull_request:
    types: [labeled]
jobs:
  security:
    concurrency: x
    uses: ./.github/workflows/security.yml"
out="$(cd "$TMP" && WORKFLOW_REF="acme/app/.github/workflows/no-existe.yml@refs/heads/develop" REPO="acme/app" \
      bash --noprofile --norc -e -o pipefail "$TMP/caller-guard.sh" 2>&1)"; rc=$?
veredicto "sin el fichero del llamador: aviso, no rojo" "$rc" 0 "$out" "::warning::caller-guard"

# ── gitleaks-install ─────────────────────────────────────────────────────────────────────────────
echo "== gitleaks-install: version fija y checksum =="
mkdir -p "$TMP/fake-install"
cat > "$TMP/fake-install/curl" <<'FAKE'
#!/usr/bin/env bash
out=""; while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac; done
printf 'no soy el tarball de gitleaks\n' > "$out"
FAKE
cat > "$TMP/fake-install/uname" <<'FAKE'
#!/usr/bin/env bash
case "$1" in -s) echo "${FAKE_OS:-Linux}" ;; -m) echo "${FAKE_ARCH:-x86_64}" ;; esac
FAKE
chmod +x "$TMP/fake-install/"*
instala() { # instala <caso> <exit> <os> <arch> <debe>
  local rt="$TMP/rt-install-$PASS-$FAIL" out rc=0
  mkdir -p "$rt"
  out="$(PATH="$TMP/fake-install:$PATH" RUNNER_TEMP="$rt" FAKE_OS="$3" FAKE_ARCH="$4" \
        bash --noprofile --norc -e -o pipefail "$TMP/gitleaks-install.sh" 2>&1)" || rc=$?
  veredicto "$1" "$rc" "$2" "$out" "$5"
  [ ! -e "$rt/gitleaks/gitleaks" ] || { FAIL=$((FAIL + 1)); echo "  FAIL $1 — dejo un binario sin verificar"; }
}
instala "descarga que no cuadra con el checksum: no se ejecuta" 1 Linux x86_64 "esperado 551f6fc83ea4"
instala "arm64 usa su propio checksum" 1 Linux aarch64 "esperado e4a487ee7ccd"
instala "runner que no es Linux: rechazado" 1 Darwin arm64 "runner no soportado"

# ── secrets ──────────────────────────────────────────────────────────────────────────────────────
echo "== secrets: alcance segun el evento, salida redactada, 0/1/2 =="
REPO_PR="$TMP/repo-pr"
gitq init -q "$REPO_PR" || exit 1
echo a > "$REPO_PR/a.txt"; gitq -C "$REPO_PR" add -A; gitq -C "$REPO_PR" commit -qm base || exit 1
gitq -C "$REPO_PR" checkout -qb rama || exit 1
echo b > "$REPO_PR/b.txt"; gitq -C "$REPO_PR" add -A; gitq -C "$REPO_PR" commit -qm rama || exit 1
gitq -C "$REPO_PR" checkout -q develop || exit 1
echo c > "$REPO_PR/c.txt"; gitq -C "$REPO_PR" add -A; gitq -C "$REPO_PR" commit -qm base-avanza || exit 1
gitq -C "$REPO_PR" merge -q --no-ff -m merge rama || exit 1
P1="$(git -C "$REPO_PR" rev-parse 'HEAD^1')"; P2="$(git -C "$REPO_PR" rev-parse 'HEAD^2')"
BASE0="$(git -C "$REPO_PR" rev-parse 'HEAD^1^')"

secretos() { # secretos <caso> <exit> <repo> <gl_rc> <evento> <base> <head> <before> <after> <debe-en-args|-> <no-debe-en-args|-> [debe-en-salida]
  local rt="$TMP/rt-sec-$PASS-$FAIL" out rc=0
  mkdir -p "$rt/gitleaks"
  cat > "$rt/gitleaks/gitleaks" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$GL_LOG"
informe=""; prev=""
for a in "$@"; do [ "$prev" = "--report-path" ] && informe="$a"; prev="$a"; done
if [ "$GL_RC" = 3 ]; then
  printf '%s' '[{"RuleID":"generic-api-key","File":"src/a,b.txt","StartLine":3,"Commit":"0123456789abcdef","Fingerprint":"0123456789abcdef:src/a,b.txt:generic-api-key:3","Secret":"REDACTED"}]' > "$informe"
fi
exit "$GL_RC"
FAKE
  chmod +x "$rt/gitleaks/gitleaks"
  out="$(cd "$3" && RUNNER_TEMP="$rt" GL_LOG="$rt/args" GL_RC="$4" EVENT_NAME="$5" PR_BASE_SHA="$6" PR_HEAD_SHA="$7" \
        PUSH_BEFORE="$8" PUSH_AFTER="$9" GITHUB_STEP_SUMMARY="$rt/summary" \
        bash --noprofile --norc -e -o pipefail "$TMP/secrets.sh" 2>&1)" || rc=$?
  local args; args="$(cat "$rt/args" 2>/dev/null)"
  veredicto "$1" "$rc" "$2" "$out
ARGS: $args" "${10}" "${11}"
  if ! grep -qF -- "--redact" <<< "$args"; then FAIL=$((FAIL + 1)); echo "  FAIL $1 — gitleaks sin --redact"; fi
  if [ -n "${12:-}" ] && ! grep -qF -- "${12}" <<< "$out"; then FAIL=$((FAIL + 1)); echo "  FAIL $1 — falta en la salida «${12}»"; fi
}
Z=0000000000000000000000000000000000000000
secretos "PR (commit de merge): solo los commits de la PR" 0 "$REPO_PR" 0 pull_request "$BASE0" "$P2" "" "" "--log-opts=$P1..$P2" -
secretos "push: los commits empujados" 0 "$REPO_PR" 0 push "" "" "$BASE0" "$P1" "--log-opts=$BASE0..$P1" -
secretos "push de rama nueva (before a ceros): historia completa" 0 "$REPO_PR" 0 push "" "" "$Z" "$P1" - "--log-opts" "historia completa"
secretos "schedule: historia completa" 0 "$REPO_PR" 0 schedule "" "" "" "" - "--log-opts" "historia completa"
secretos "hallazgo: rojo con anotacion escapada y huella" 1 "$REPO_PR" 3 schedule "" "" "" "" - - "::error file=src/a%2Cb.txt,line=3::gitleaks generic-api-key"
secretos "gitleaks roto: no medido (2), nunca verde" 2 "$REPO_PR" 1 schedule "" "" "" "" - - "no se pudo medir"
REPO_LINEAL="$TMP/repo-lineal"
gitq clone -q "$REPO_PR" "$REPO_LINEAL" && gitq -C "$REPO_LINEAL" checkout -q "$P2"
secretos "PR sin commit de merge: base..cabeza del evento" 0 "$REPO_LINEAL" 0 pull_request "$BASE0" "$P2" "" "" "--log-opts=$BASE0..$P2" -

# ── audit ────────────────────────────────────────────────────────────────────────────────────────
echo "== audit: npm/pnpm, modo PR (lo que anade) y modo absoluto =="
mkdir -p "$TMP/fake-pm"
# Los avisos van escritos en el propio lockfile de prueba, una linea por aviso:
#   vuln <GHSA> <severidad> <paquete>
# y `boom` hace que el gestor devuelva basura en vez de un informe.
cat > "$TMP/fake-pm/pnpm" <<'FAKE'
#!/usr/bin/env bash
printf 'pnpm %s @ %s\n' "$*" "$(pwd)" >> "$PM_LOG"
lock=pnpm-lock.yaml
if grep -q boom "$lock"; then echo "ERR_PNPM_AUDIT_BAD_RESPONSE The audit endpoint responded with 500"; exit 1; fi
printf '{"advisories":{'
n=0
while read -r _ id sev mod; do
  [ $n -gt 0 ] && printf ','
  n=$((n + 1))
  printf '"%s":{"id":%s,"github_advisory_id":"%s","severity":"%s","module_name":"%s","title":"t %s","url":"https://github.com/advisories/%s"}' "$n" "$n" "$id" "$sev" "$mod" "$mod" "$id"
done < <(grep '^vuln ' "$lock")
printf '},"metadata":{}}\n'
[ $n -eq 0 ]
FAKE
cat > "$TMP/fake-pm/npm" <<'FAKE'
#!/usr/bin/env bash
printf 'npm %s @ %s\n' "$*" "$(pwd)" >> "$PM_LOG"
lock=package-lock.json
if grep -q boom "$lock"; then printf '{"message":"request failed","error":{"summary":"","detail":""}}\n'; exit 1; fi
printf '{"vulnerabilities":{'
n=0
while read -r _ id sev mod; do
  [ $n -gt 0 ] && printf ','
  n=$((n + 1))
  printf '"%s":{"name":"%s","severity":"%s","via":[{"source":%s,"name":"%s","title":"t %s","url":"https://github.com/advisories/%s","severity":"%s"},"otro-paquete"]}' "$mod" "$mod" "$sev" "$n" "$mod" "$mod" "$id" "$sev"
done < <(grep '^vuln ' "$lock")
printf '},"metadata":{}}\n'
[ $n -eq 0 ]
FAKE
chmod +x "$TMP/fake-pm/"*

# repo <lockfile|-> <contenido...>: repo nuevo con un commit; imprime su ruta. Todo con `git -C` y
# rutas absolutas: un `cd` fallido NUNCA debe dejar un commit de prueba en el repo que se prueba.
repo() {
  local d f=$1; shift
  d="$(mktemp -d "$TMP/audit-XXXXXX")" || exit 1
  gitq init -q "$d" || exit 1
  echo '{"name":"x"}' > "$d/package.json"
  if [ "$f" != "-" ]; then mkdir -p "$(dirname "$d/$f")"; printf '%s\n' "$@" > "$d/$f"; fi
  gitq -C "$d" add -A && gitq -C "$d" commit -qm base || exit 1
  printf '%s' "$d"
}
# pr <repo> <fichero> <contenido...>: rama que cambia el fichero y commit de merge encima de la base
pr() {
  local d=$1 f=$2; shift 2
  case "$d" in "$TMP"/*) ;; *) echo "FATAL: pr() fuera de \$TMP: $d"; exit 1 ;; esac
  gitq -C "$d" checkout -qb pr || exit 1
  mkdir -p "$(dirname "$d/$f")"; printf '%s\n' "$@" > "$d/$f"
  gitq -C "$d" add -A && gitq -C "$d" commit -qm cambio || exit 1
  gitq -C "$d" checkout -q develop || exit 1
  echo x >> "$d/otro.txt"
  gitq -C "$d" add -A && gitq -C "$d" commit -qm base-avanza || exit 1
  gitq -C "$d" merge -q --no-ff -m merge pr || exit 1
}
repo_ok() { local r; r="$(repo "$@")" && [ -d "$r/.git" ] || { echo "FATAL: no pude crear el repo de prueba" >&2; exit 1; }; printf '%s' "$r"; }
audita() { # audita <caso> <exit> <repo> <evento> <nivel> <ignora> <workdir> <debe|-> <no-debe|-> [llamadas-esperadas]
  local rt="$TMP/rt-audit-$PASS-$FAIL" out rc=0
  mkdir -p "$rt"; : > "$rt/pm.log"
  out="$(cd "$3" && PATH="$TMP/fake-pm:$PATH" RUNNER_TEMP="$rt" PM_LOG="$rt/pm.log" EVENT_NAME="$4" PR_BASE_SHA="" PUSH_BEFORE="" \
        AUDIT_LEVEL="$5" IGNORE="$6" WORKDIR="$7" GITHUB_STEP_SUMMARY="$rt/summary" \
        bash --noprofile --norc -e -o pipefail "$TMP/audit.sh" 2>&1)" || rc=$?
  veredicto "$1" "$rc" "$2" "$out" "$8" "$9"
  if [ -n "${10:-}" ]; then
    local n; n="$(grep -c . "$rt/pm.log" || true)"
    if [ "$n" -ne "${10}" ]; then FAIL=$((FAIL + 1)); echo "  FAIL $1 — esperaba ${10} llamada(s) al gestor, hubo $n"; cat "$rt/pm.log"; fi
  fi
}

R="$(repo_ok -)"
audita "sin lockfile: nada que auditar" 0 "$R" schedule high "" . "no hay dependencias que auditar" - 0
R="$(repo_ok pubspec.lock "packages:")"
audita "pubspec.lock: aviso de que pub no tiene auditor" 0 "$R" schedule high "" . "pub no tiene auditor" - 0
R="$(repo_ok pnpm-lock.yaml "lockfileVersion: '9.0'" "vuln GHSA-aaaa-aaaa-aaaa high lodash")"
audita "schedule con un aviso high: rojo" 1 "$R" schedule high "" . "::error::pnpm audit: GHSA-aaaa-aaaa-aaaa (high) en lodash" - 1
audita "el mismo aviso ignorado por su GHSA (sin distinguir mayusculas): verde" 0 "$R" schedule high "ghsa-AAAA-aaaa-aaaa, GHSA-zzzz-zzzz-zzzz" . "ningun aviso" "::error::"
audita "nivel critical: el high no cuenta" 0 "$R" schedule critical "" . "ningun aviso >= critical" -
audita "nivel invalido: no medido" 2 "$R" schedule alto "" . "audit-level 'alto'" - 0
audita "working-directory que no existe: no medido" 2 "$R" schedule high "" no-existe "working-directory 'no-existe'" - 0
R="$(repo_ok pnpm-lock.yaml "vuln GHSA-bbbb-bbbb-bbbb moderate minimist")"
audita "solo moderate con nivel high: verde" 0 "$R" schedule high "" . "ningun aviso >= high" -
audita "moderate con nivel low: rojo" 1 "$R" schedule low "" . "GHSA-bbbb-bbbb-bbbb (moderate)" -
R="$(repo_ok pnpm-lock.yaml "boom")"
audita "el gestor devuelve basura: no medido (2)" 2 "$R" schedule high "" . "no devolvio un informe" -
R="$(repo_ok package-lock.json '{"lockfileVersion":3}' "vuln GHSA-cccc-cccc-cccc critical minimist")"
audita "npm: aviso critical desde via[]" 1 "$R" schedule high "" . "::error::npm audit: GHSA-cccc-cccc-cccc (critical) en minimist" -
R="$(repo_ok package-lock.json "boom")"
audita "npm con error de red: no medido (2)" 2 "$R" workflow_dispatch high "" . "no devolvio un informe" -
R="$(repo_ok app/pnpm-lock.yaml "vuln GHSA-dddd-dddd-dddd high lodash")"
audita "working-directory con el lockfile en una subcarpeta" 1 "$R" schedule high "" app "GHSA-dddd-dddd-dddd" -

R="$(repo_ok pnpm-lock.yaml "vuln GHSA-eeee-eeee-eeee high viejo")"
pr "$R" README.md "solo docs"
audita "PR que no toca dependencias: no audita (aunque haya avisos viejos)" 0 "$R" pull_request high "" . "no toca dependencias" "::error::" 0
R="$(repo_ok pnpm-lock.yaml "vuln GHSA-eeee-eeee-eeee high viejo")"
pr "$R" pnpm-lock.yaml "vuln GHSA-eeee-eeee-eeee high viejo" "vuln GHSA-ffff-ffff-ffff critical nuevo"
audita "PR que anade un aviso: rojo solo por el nuevo" 1 "$R" pull_request high "" . "::error::pnpm audit: GHSA-ffff-ffff-ffff (critical) en nuevo" "::error::pnpm audit: GHSA-eeee" 2
audita "... y el viejo sale como aviso" 1 "$R" pull_request high "" . "::warning::pnpm audit: GHSA-eeee-eeee-eeee (high) en viejo ya estaba en la base" -
R="$(repo_ok pnpm-lock.yaml "vuln GHSA-eeee-eeee-eeee high viejo")"
pr "$R" pnpm-lock.yaml "vuln GHSA-eeee-eeee-eeee high viejo" "# otra linea"
audita "PR que toca el lockfile sin anadir avisos: verde con aviso" 0 "$R" pull_request high "" . "no anade avisos" "::error::" 2
R="$(repo_ok -)"
pr "$R" pnpm-lock.yaml "vuln GHSA-gggg-gggg-gggg high primero"
audita "PR que estrena el lockfile: todo lo que trae es nuevo" 1 "$R" pull_request high "" . "GHSA-gggg-gggg-gggg" - 1

echo
echo "security.test.sh: $PASS ok, $FAIL fallos"
[ "$FAIL" -eq 0 ]
