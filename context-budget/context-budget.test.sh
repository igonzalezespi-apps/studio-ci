#!/usr/bin/env bash
# context-budget.test.sh — dispara `context-budget.sh` contra el fixture `limpio` y contra UNA
# mutacion suya por caso.
#
# POR DISPARO, NUNCA POR PRESENCIA, y cada regla con su pareja: la mutacion que la rompe falla
# CON SU MOTIVO (la linea que lo dice), y la que queda justo en el limite o en la excepcion
# pasa. Sin las dos mitades, «no falla» no se distingue de «dejo de mirar»; y sin comprobar el
# motivo, un script que fallara por otra cosa haria pasar el caso por accidente.
#
# El fixture se guarda sin puntos (`dot-claude/`, `dot-github/`, `CLAUDE.fixture.md`) para que
# este arbol no se cargue como configuracion real en este repositorio; `prepara` lo copia con
# sus nombres de verdad a un directorio temporal. Sin red.
# shellcheck disable=SC2016,SC2329 # las mutaciones viajan como texto a `eval`, a proposito
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$HERE/context-budget.sh"
FIX="$HERE/fixtures/limpio"
[ -f "$CHECK" ] || { echo "no encuentro $CHECK"; exit 1; }
[ -d "$FIX" ] || { echo "no encuentro $FIX"; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
R="$TMP/repo"

prepara() { # copia el fixture a $R con los nombres reales
  rm -rf "$R"; cp -R "$FIX" "$R"
  mv "$R/dot-claude" "$R/.claude"
  mv "$R/dot-github" "$R/.github"
  mv "$R/plugins/nucleo/dot-claude-plugin" "$R/plugins/nucleo/.claude-plugin"
  mv "$R/CLAUDE.fixture.md" "$R/CLAUDE.md"
}

# rellena <fichero> <bytes>: sustituye el contenido por N bytes ASCII
rellena() { python3 -c 'import sys;open(sys.argv[1],"w").write("x"*int(sys.argv[2]))' "$1" "$2"; }
# jqset <fichero> <expresion-python sobre d>: edita un JSON sin depender de jq
jqset() {
  python3 - "$1" "$2" <<'PYJ'
import json, sys
p, expr = sys.argv[1], sys.argv[2]
d = json.load(open(p))
exec(expr)
json.dump(d, open(p, "w"), indent=2)
PYJ
}
# desc <fichero> <n>: fija la description del frontmatter a N caracteres
desc() {
  python3 - "$1" "$2" <<'PYD'
import re, sys
p, n = sys.argv[1], int(sys.argv[2])
t = open(p, encoding="utf-8").read()
t = re.sub(r"^description:.*?(?=^[a-z_-]+:|^---)", "description: " + "d" * n + "\n", t, count=1, flags=re.M | re.S)
open(p, "w", encoding="utf-8").write(t)
PYD
}

# caso <exit-esperado> <etiqueta> <texto-que-debe-salir> <mutacion> [args del script...]
caso() {
  local want="$1" label="$2" esperado="$3" mut="$4"; shift 4
  prepara
  ( cd "$R" && eval "$mut" ) || { fail=$((fail + 1)); printf 'FAIL  %s: la mutacion no se pudo aplicar\n' "$label"; return; }
  local out rc=0
  out="$(bash "$CHECK" --root "$R" "$@" 2>&1)" || rc=$?
  if [ "$rc" -ne "$want" ]; then
    fail=$((fail + 1)); printf 'FAIL  %s (esperaba exit %s, salio %s)\n%s\n' "$label" "$want" "$rc" "$out"; return
  fi
  if [ -n "$esperado" ] && ! printf '%s' "$out" | grep -qF -- "$esperado"; then
    fail=$((fail + 1)); printf 'FAIL  %s: la salida no dice «%s»\n%s\n' "$label" "$esperado" "$out"; return
  fi
  pass=$((pass + 1))
}

LIMPIO="context-budget: 0 violacion(es), 0 aviso(s)"

# --- el fixture limpio pasa, y revisa algo en cada comprobacion -------------------------------
caso 0 "fixture limpio: 0 violaciones" "$LIMPIO" ":"
prepara
out="$(bash "$CHECK" --root "$R" 2>&1)"
for c in size descriptions dated marketplace output-style user-keys agents pact; do
  if printf '%s\n' "$out" | grep -qE "^OK    \[$c\] [1-9]"; then pass=$((pass + 1)); else
    fail=$((fail + 1)); printf 'FAIL  el fixture limpio no ejercita [%s] (0 revisados): un OK sin mirar nada\n%s\n' "$c" "$out"; fi
done

# --- size -------------------------------------------------------------------------------------
caso 1 "CLAUDE.md de 3.001 B" "FAIL  [size] CLAUDE.md: 3.001 B > 3.000 B" 'rellena CLAUDE.md 3001; echo "Pacto contrato TASKS v2" >> /dev/null'
caso 0 "CLAUDE.md de 3.000 B justos (sin pacto: se quita TASKS.md)" "" 'rellena CLAUDE.md 3000; rm TASKS.md'
caso 1 "estilo de salida de 5.001 B" "FAIL  [size] plugins/nucleo/output-styles/dueno.md: 5.001 B" \
  'python3 -c "import sys;p=sys.argv[1];t=open(p).read();open(p,\"w\").write(t+\"y\"*(5001-len(t.encode())))" plugins/nucleo/output-styles/dueno.md'
# contract-core se mide en CARACTERES: 3.999 caracteres con tildes son mas de 4.000 bytes y pasan
caso 0 "contract-core de 3.999 caracteres (y mas de 4.000 bytes)" "" \
  'python3 -c "open(\"plugins/nucleo/policy/contract-core.md\",\"w\",encoding=\"utf-8\").write(\"á\"*3999)"'
caso 1 "contract-core de 4.001 caracteres" "FAIL  [size] plugins/nucleo/policy/contract-core.md: 4.001 caracteres > 4.000" \
  'python3 -c "open(\"plugins/nucleo/policy/contract-core.md\",\"w\",encoding=\"utf-8\").write(\"a\"*4001)"'
caso 0 "un CLAUDE.md anidado no tiene el limite del de la raiz" "" 'mkdir -p docs && rellena docs/CLAUDE.md 9000'

# --- descriptions -----------------------------------------------------------------------------
caso 1 "description de skill de 251 caracteres" "FAIL  [descriptions] .claude/skills/resumen/SKILL.md:3: description de 251 caracteres > 250" \
  'desc .claude/skills/resumen/SKILL.md 251'
caso 0 "description de skill de 250 justos" "" 'desc .claude/skills/resumen/SKILL.md 250'
caso 1 "description de agente de 300" "FAIL  [descriptions] .claude/agents/lector.md" 'desc .claude/agents/lector.md 300'
caso 0 "comando de 400 con disable-model-invocation: no entra en el listado" "" 'desc plugins/nucleo/commands/publicar.md 400'
caso 1 "when_to_use cuenta con la description" "description de 280 caracteres > 250" \
  'sed -i "s/^when_to_use: .*/when_to_use: $(printf "w%.0s" $(seq 1 200))/" plugins/nucleo/skills/revisar/SKILL.md'
# 25 skills de 245: cada una cabe, la suma (6.125 + las del plugin) no
caso 1 "suma del listado de un plugin > 6.000" "el listado de nucleo suma" \
  'for k in $(seq 1 25); do mkdir -p plugins/nucleo/skills/s$k; printf -- "---\nname: s$k\ndescription: %s\n---\n" "$(printf "e%.0s" $(seq 1 245))" > plugins/nucleo/skills/s$k/SKILL.md; done'
caso 0 "la misma suma con disable-model-invocation no cuenta" "" \
  'for k in $(seq 1 25); do mkdir -p plugins/nucleo/skills/s$k; printf -- "---\nname: s$k\ndescription: %s\ndisable-model-invocation: true\n---\n" "$(printf "e%.0s" $(seq 1 245))" > plugins/nucleo/skills/s$k/SKILL.md; done'
caso 0 "los agentes no suman al listado de skills" "" \
  'for k in $(seq 1 30); do printf -- "---\nname: a$k\ndescription: %s\nmodel: sonnet\neffort: low\n---\n" "$(printf "e%.0s" $(seq 1 245))" > plugins/nucleo/agents/a$k.md; done'
# frontmatter que no es YAML valido (dos puntos sin comillas): Claude Code lo carga y aqui se mide
caso 1 "description con dos puntos sin comillas se mide igual" "description de 260" \
  'sed -i "s/^description: Resume.*/description: nota: $(printf "z%.0s" $(seq 1 254))/" .claude/skills/resumen/SKILL.md'

# --- dated ------------------------------------------------------------------------------------
caso 1 "linea con fecha ISO en CLAUDE.md" "FAIL  [dated] CLAUDE.md:13: parrafo fechado (fecha: «2026-09-29»)" \
  'printf "\nMedido el 2026-09-29 con el comando de siempre.\n" >> CLAUDE.md'
caso 1 "nota de correccion sin fecha" "nota de correccion" 'printf "\n*(Corregido: antes decia otra cosa.)*\n" >> CLAUDE.md'
caso 1 "«esta linea decia» sin fecha" "antes decia" 'printf "\nHasta hoy esta regla decia lo contrario.\n" >> CLAUDE.md'
caso 1 "fecha corta «el 29-09»" "«el 29-09»" 'printf "\nSe cambio el 29-09 por una incidencia.\n" >> CLAUDE.md'
caso 1 "fecha en una regla por ruta" "FAIL  [dated] .claude/rules/ci.md:1" 'mkdir -p .claude/rules && echo "Desde el 12 de agosto va asi." > .claude/rules/ci.md'
caso 0 "la misma fecha con la marca de excepcion" "" 'printf "\nNode 24 (2026-09-29) <!-- context-budget: allow -->\n" >> CLAUDE.md'
caso 0 "una fecha dentro de un bloque de codigo no cuenta" "" 'printf "\n\`\`\`\ngit log --since 2026-09-29\n\`\`\`\n" >> CLAUDE.md'
caso 0 "una fecha en un README no es un fichero de reglas" "" 'echo "Publicado el 2026-09-29." >> README.md'

# --- marketplace ------------------------------------------------------------------------------
caso 1 "marketplace canonico sin ref" 'extraKnownMarketplaces.ivan sin "ref": "main"' \
  'jqset .claude/settings.json "del d[\"extraKnownMarketplaces\"][\"ivan\"][\"source\"][\"ref\"]"'
caso 1 "marketplace canonico con ref develop" '(tiene "develop")' \
  'jqset .claude/settings.json "d[\"extraKnownMarketplaces\"][\"ivan\"][\"source\"][\"ref\"]=\"develop\""'
caso 1 "marketplace en la ruta antigua" "apunta a la ruta antigua igonzalezespi/claude-plugins" \
  'jqset .claude/settings.json "d[\"extraKnownMarketplaces\"][\"ivan\"][\"source\"][\"repo\"]=\"igonzalezespi/claude-plugins\""'
caso 0 "fuente git por SSH con ref main" "" \
  'jqset .claude/settings.json "d[\"extraKnownMarketplaces\"][\"ivan\"][\"source\"]={\"source\":\"git\",\"url\":\"git@github.com:igonzalezespi-apps/claude-plugins.git\",\"ref\":\"main\"}"'
caso 1 "fuente git por SSH sin ref" "sin \"ref\"" \
  'jqset .claude/settings.json "d[\"extraKnownMarketplaces\"][\"ivan\"][\"source\"]={\"source\":\"git\",\"url\":\"git@github.com:igonzalezespi-apps/claude-plugins.git\"}"'
caso 0 "otro marketplace, sin ref: no es el canonico" "" \
  'jqset .claude/settings.json "d[\"extraKnownMarketplaces\"][\"otro\"]={\"source\":{\"source\":\"github\",\"repo\":\"acme/plugins\"}}"'
caso 1 "workflow que clona sin --branch (partido en dos lineas)" "FAIL  [marketplace] .github/workflows/ci.yml:9: clona igonzalezespi-apps/claude-plugins sin --branch main" \
  'sed -i "s/ --branch main//" .github/workflows/ci.yml'
caso 1 "workflow con la ruta antigua en codigo" "usa la ruta antigua" \
  'echo "      - run: git clone --branch main https://github.com/igonzalezespi/claude-plugins.git x" >> .github/workflows/ci.yml'
caso 1 "checkout del marketplace sin ref" "checkout de igonzalezespi-apps/claude-plugins sin ref: main" \
  'sed -i "/^          ref: main$/d" .github/workflows/ci.yml'
caso 0 "un repo que se llama parecido no es el canonico" "" \
  'echo "      - run: git clone https://github.com/igonzalezespi-apps/claude-plugins-extra.git y" >> .github/workflows/ci.yml'

# --- output-style -----------------------------------------------------------------------------
caso 1 "estilo de un plugin no habilitado" "el plugin nucleo no esta habilitado" \
  'jqset .claude/settings.json "d[\"enabledPlugins\"][\"nucleo@ivan\"]=False"'
caso 1 "el plugin no trae ese estilo" "el plugin nucleo no trae el estilo otro (trae: dueno)" \
  'jqset .claude/settings.json "d[\"outputStyle\"]=\"nucleo:otro\""'
caso 0 "estilo integrado" "" 'jqset .claude/settings.json "d[\"outputStyle\"]=\"Explanatory\""'
caso 0 "estilo del proyecto que existe" "" 'jqset .claude/settings.json "d[\"outputStyle\"]=\"breve\""'
caso 1 "estilo del proyecto que no existe" "outputStyle \"largo\" no es un estilo integrado" \
  'jqset .claude/settings.json "d[\"outputStyle\"]=\"largo\""'
# un plugin de fuera del repo: sin copia del marketplace no se puede ver, y NO se inventa un fallo
caso 0 "plugin externo sin copia del marketplace: no verificable, no falla" "no se puede ver sin una copia" \
  'jqset .claude/settings.json "d[\"outputStyle\"]=\"ajeno:dueno\"; d[\"enabledPlugins\"][\"ajeno@ivan\"]=True"'
mk="$TMP/mkts"; rm -rf "$mk"; mkdir -p "$mk/ivan/plugins/ajeno/output-styles" "$mk/ivan/.claude-plugin"
printf '{"name":"ivan","plugins":[{"name":"ajeno","source":"./plugins/ajeno"}]}\n' > "$mk/ivan/.claude-plugin/marketplace.json"
printf -- '---\nname: dueno\n---\nx\n' > "$mk/ivan/plugins/ajeno/output-styles/dueno.md"
caso 0 "plugin externo con copia del marketplace que trae el estilo" "ajeno:dueno (resuelve)" \
  'jqset .claude/settings.json "d[\"outputStyle\"]=\"ajeno:dueno\"; d[\"enabledPlugins\"][\"ajeno@ivan\"]=True"' --marketplaces-dir "$mk"
caso 1 "plugin externo con copia del marketplace que NO trae el estilo" "no trae el estilo otro" \
  'jqset .claude/settings.json "d[\"outputStyle\"]=\"ajeno:otro\"; d[\"enabledPlugins\"][\"ajeno@ivan\"]=True"' --marketplaces-dir "$mk"
caso 1 "estilo distinto del acordado" 'outputStyle "breve", y el acordado es "nucleo:dueno"' \
  'jqset .claude/settings.json "d[\"outputStyle\"]=\"breve\""; echo "{\"output_style_expected\": \"nucleo:dueno\"}" > .context-budget.json'
caso 1 "sin estilo cuando hay uno acordado" "outputStyle sin declarar" \
  'jqset .claude/settings.json "del d[\"outputStyle\"]"; echo "{\"output_style_expected\": \"nucleo:dueno\"}" > .context-budget.json'

# --- user-keys --------------------------------------------------------------------------------
caso 1 "model en el settings del repo" '"model" es un ajuste personal' 'jqset .claude/settings.json "d[\"model\"]=\"opus\""'
caso 1 "effortLevel en el settings del repo" '"effortLevel" es un ajuste personal' 'jqset .claude/settings.json "d[\"effortLevel\"]=\"high\""'
caso 1 "autoCompactWindow en el settings del repo" '"autoCompactWindow"' 'jqset .claude/settings.json "d[\"autoCompactWindow\"]=400000"'
caso 1 "plugin de un marketplace que el repo no declara (aunque sea false)" 'enabledPlugins "ingenieria@sincronizado"' \
  'jqset .claude/settings.json "d[\"enabledPlugins\"][\"ingenieria@sincronizado\"]=False"'
caso 0 "las claves personales en settings.local.json son de su sitio" "" \
  'echo "{\"model\":\"opus\",\"effortLevel\":\"high\"}" > .claude/settings.local.json'
caso 1 "settings.json ilegible" "JSON ilegible" 'echo "{ roto" > .claude/settings.json'

# --- agents -----------------------------------------------------------------------------------
caso 1 "agente sin effort" "FAIL  [agents] .claude/agents/lector.md:1: sin effort" 'sed -i "/^effort:/d" .claude/agents/lector.md'
caso 1 "agente sin model" "sin model" 'sed -i "/^model:/d" .claude/agents/escritor.md'
caso 0 "haiku sin effort: no lo admite, no se exige" "" ":"
caso 1 "memory en un agente de solo lectura" "memory: project en un agente de solo lectura" \
  'sed -i "s/^tools: .*/tools: Read, Grep, Glob\nmemory: project/" .claude/agents/lector.md'
caso 0 "memory en un agente sin lista de tools (las hereda todas)" "" \
  'sed -i "/^tools:/d; s/^effort: .*/effort: medium\nmemory: user/" .claude/agents/lector.md'
caso 1 "memory con Write y Edit prohibidos" "solo lectura" \
  'sed -i "/^tools:/d; s/^effort: .*/effort: medium\nmemory: user\ndisallowedTools: Write, Edit/" .claude/agents/lector.md'
# `tools` como lista YAML en la columna 0: sigue siendo de solo lectura
caso 1 "memory con tools en lista YAML sin indentar" "memory: local en un agente de solo lectura" \
  'printf -- "---\nname: l2\ndescription: lee\nmodel: sonnet\neffort: low\nmemory: local\ntools:\n- Read\n- Grep\n---\nx\n" > .claude/agents/l2.md'
caso 1 "agente sin frontmatter" "sin frontmatter" 'echo "solo prosa" > plugins/nucleo/agents/rastreador.md'
caso 0 "un agente bajo tests/ no se revisa" "" 'mkdir -p tests/.claude/agents && echo "sin nada" > tests/.claude/agents/x.md'

# --- pact -------------------------------------------------------------------------------------
caso 1 "pacto duplicado en CLAUDE.md" "2 linea(s) con «contrato TASKS v2»" \
  'echo "- Otra vez el contrato TASKS v2." >> CLAUDE.md'
caso 1 "sin la linea del pacto" "0 linea(s) con «contrato TASKS v2»" 'sed -i "/contrato TASKS v2/d" CLAUDE.md'
caso 1 "copia vieja del pacto (v1) junto a la buena" "copia vieja del pacto" \
  'echo "- **Tablero pact** — registro por repo y traspaso en TASKS.md." >> CLAUDE.md'
caso 1 "copia del pacto en una regla por ruta" "FAIL  [pact] .claude/rules/tablero.md:1: otra copia del pacto" \
  'mkdir -p .claude/rules && echo "Pacto Tablero: deja la entrada en A medias." > .claude/rules/tablero.md'
caso 0 "sin TASKS.md el pacto no aplica" "sin TASKS.md: no aplica" 'rm TASKS.md; sed -i "/contrato TASKS v2/d" CLAUDE.md'

# --- etiqueta de aprobacion y modos -----------------------------------------------------------
caso 0 "exceso de presupuesto CON la etiqueta: aprobado y visible" "APROB [size] CLAUDE.md" \
  'rellena CLAUDE.md 4000; echo "contrato TASKS v2" >> CLAUDE.md' --labels "semver:none,presupuesto-contexto-aprobado"
caso 1 "la etiqueta no arregla la configuracion" "FAIL  [output-style]" \
  'jqset .claude/settings.json "d[\"outputStyle\"]=\"largo\""' --labels "presupuesto-contexto-aprobado"
caso 1 "otra etiqueta no aprueba nada" "FAIL  [size] CLAUDE.md" \
  'rellena CLAUDE.md 4000; echo "contrato TASKS v2" >> CLAUDE.md' --labels "revision-humana"
caso 0 "modo warn: avisa y no falla" "context-budget: 0 violacion(es), 1 aviso(s)" \
  'jqset .claude/settings.json "d[\"model\"]=\"opus\""' --mode warn
caso 0 "warn_checks en la configuracion" "WARN  [user-keys]" \
  'jqset .claude/settings.json "d[\"model\"]=\"opus\""; echo "{\"warn_checks\": [\"user-keys\"]}" > .github/context-budget.json'
caso 0 "skip_checks en la configuracion" "--    [user-keys] desactivada" \
  'jqset .claude/settings.json "d[\"model\"]=\"opus\""; echo "{\"skip_checks\": [\"user-keys\"]}" > .github/context-budget.json'
caso 0 "--mode warn manda sobre el mode del JSON" "WARN" \
  'jqset .claude/settings.json "d[\"model\"]=\"opus\""; echo "{\"mode\": \"enforce\"}" > .context-budget.json' --mode warn
caso 1 "limites propios en la configuracion" "FAIL  [size] CLAUDE.md" \
  'echo "{\"limits\": [{\"glob\": \"CLAUDE.md\", \"max_bytes\": 100}]}" > .github/context-budget.json'

# --- no se puede medir: exit 2, nunca un 0 silencioso -----------------------------------------
caso 2 "configuracion ilegible" "configuracion ilegible" 'echo "{ roto" > .github/context-budget.json'
caso 2 "clave desconocida en la configuracion" "clave(s) desconocida(s)" 'echo "{\"limite\": 1}" > .github/context-budget.json'
caso 2 "comprobacion desconocida" "comprobacion desconocida" 'echo "{\"warn_checks\": [\"G3\"]}" > .github/context-budget.json'
caso 2 "un limite mal escrito" "cada limite es" 'echo "{\"limits\": [\"CLAUDE.md\"]}" > .github/context-budget.json'
caso 2 "una lista que no es lista" "tiene que ser una lista" 'echo "{\"exclude\": \"**/x/**\"}" > .github/context-budget.json'
# un fallo interno sale con 2 («no se pudo medir»), nunca con 1 («hay violaciones»)
caso 2 "fallo interno: exit 2 y lo dice" "error interno" 'echo "{\"pact\": {\"aliases\": 7}}" > .github/context-budget.json'
caso 2 "argumento desconocido" "argumento desconocido" ":" --nada
caso 2 "modo desconocido" "modo desconocido" ":" --mode estricto

# --- anotaciones para GitHub ------------------------------------------------------------------
caso 1 "--annotations saca ::error con fichero y linea" "::error file=CLAUDE.md,line=13,title=context-budget [dated]::" \
  'printf "\nMedido el 2026-09-29.\n" >> CLAUDE.md' --annotations

# --- en un repo git, lo ignorado no se mide ---------------------------------------------------
prepara
( cd "$R" && git init -q && mkdir -p .claude/rules && echo "Desde el 2026-09-29." > .claude/rules/local.md \
  && echo ".claude/rules/local.md" > .gitignore )
out="$(bash "$CHECK" --root "$R" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); printf 'FAIL  un fichero ignorado por git se midio\n%s\n' "$out"; fi
( cd "$R" && : > .gitignore )
out="$(bash "$CHECK" --root "$R" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qF ".claude/rules/local.md:1"; then pass=$((pass + 1)); else
  fail=$((fail + 1)); printf 'FAIL  el mismo fichero sin ignorar no se midio (exit %s)\n%s\n' "$rc" "$out"; fi

echo "----------------------------------------"
[ "$fail" -eq 0 ] && { echo "OK: $pass/$((pass + fail)) casos pasan"; exit 0; }
echo "FALLOS: $fail/$((pass + fail))"; exit 1
