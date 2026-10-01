#!/usr/bin/env bash
# check.sh — una PR marcada para que la lea una persona empieza por su `## TL;DR`, y ese TL;DR
# se basta solo.
#
# POR QUE EXISTE. La marca (`revision-humana` por defecto) dice "esta PR la mergea una persona".
# Quien la mergea no lee el diff: lee esa seccion. Mientras fue solo una regla escrita, se cumplio
# a veces — y una seccion que remite a otra parte del cuerpo ("ver abajo", "segun el ADR-7") obliga
# a quien decide a reconstruir el contexto, que es justo lo que la marca queria evitar.
#
# SEIS clases de violacion, todas sobre la PR marcada:
#
#   1. no hay `## TL;DR`                      -> no hay nada escrito para quien decide
#   2. el `## TL;DR` no es la PRIMERA seccion -> queda debajo de lo tecnico y no se lee
#   3. la seccion esta practicamente vacia    -> un titular no es un resumen
#   4. remite a otro sitio                    -> "ver abajo", "mas arriba", "como en la PR X"
#   5. cita una fuente sin traerla            -> ADR-7 / decision D12 / issue #9 sin enlace ni linea
#   6. falta el comando de merge de ESTA PR   -> su "si" es un comando completo, no un clic
#
# Una PR SIN la marca no se juzga: sale 0 y lo dice. Asi el control puede estar cableado en todos
# los repos sin volverse ruido en las PRs que integra un agente.
#
# MODO PROMOCION (`--promotion`, opt-in). Una PR de la rama de integracion a la protegida
# (`develop` -> `main` por defecto) es una release: la lee siempre una persona, lleve o no la marca.
# Se juzga con las seis clases y ademas con las reglas del resumen de release, que antes vivian en
# otro linter y no coincidian con este (una sola implementacion desde ahora):
#
#   7. faltan o estan sin rellenar los cuatro campos («Qué notarán los usuarios», «Qué puede salir
#      mal y cómo se deshace», «Decisiones tuyas que van dentro», «Qué NO se ha comprobado»)
#   8. hay codigo en linea o rutas de ficheros en la prosa del TL;DR: se dice por su efecto
#   9. el comando no es exactamente `gh pr merge <n> --repo <owner>/<name> --merge` de ESTA PR, en
#      un bloque bash (una promocion entra con merge commit, nunca squash)
#
# Uso:
#   check.sh --repo <owner>/<name> --pr <n> [--label <etiqueta>] [--promotion
#            [--protected-branch main] [--integration-branch develop]]
#   check.sh --body <fichero> --pr <n> --repo <owner>/<name> --labels "a,b"
#            [--base-ref B --head-ref H]                                       (sin red; para tests)
#
# Salida: una linea por violacion y un resumen. Exit 0 si no hay ninguna, 1 si hay, 2 si no se
# puede medir (nunca un 0 silencioso: no saber no es estar limpio).
#
# `GH_API` existe para los tests: por defecto es `gh api`.
set -uo pipefail

REPO=""; PR=""; LABEL="revision-humana"; BODY_FILE=""; LABELS_IN=""
PROMOTION=0; PROTECTED="main"; INTEGRATION="develop"; BASE_REF=""; HEAD_REF=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:?falta valor para --repo}"; shift 2 ;;
    --pr) PR="${2:?falta valor para --pr}"; shift 2 ;;
    --label) LABEL="${2:?falta valor para --label}"; shift 2 ;;
    --body) BODY_FILE="${2:?falta valor para --body}"; shift 2 ;;
    # `shift 2` con un solo argumento falla sin mover nada y el bucle no termina: con valor vacio
    # se acepta, sin valor es un error de uso.
    --labels) [ $# -ge 2 ] || { echo "check-pr-tldr: falta valor para --labels" >&2; exit 2; }; LABELS_IN="$2"; shift 2 ;;
    --promotion) PROMOTION=1; shift ;;
    --protected-branch) PROTECTED="${2:?falta valor para --protected-branch}"; shift 2 ;;
    --integration-branch) INTEGRATION="${2:?falta valor para --integration-branch}"; shift 2 ;;
    --base-ref) BASE_REF="${2:?falta valor para --base-ref}"; shift 2 ;;
    --head-ref) HEAD_REF="${2:?falta valor para --head-ref}"; shift 2 ;;
    -h | --help) sed -n '/^# Uso:/,/^# Salida/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "check-pr-tldr: argumento desconocido '$1'" >&2; exit 2 ;;
  esac
done
GH_API="${GH_API:-gh api}"

[ -n "$PR" ] || { echo "check-pr-tldr: falta --pr" >&2; exit 2; }
[ -n "$REPO" ] || { echo "check-pr-tldr: falta --repo" >&2; exit 2; }

tmp="$(mktemp -d)" || exit 2
trap 'rm -rf "$tmp"' EXIT

if [ -n "$BODY_FILE" ]; then
  [ -f "$BODY_FILE" ] || { echo "check-pr-tldr: no existe $BODY_FILE" >&2; exit 2; }
  cp "$BODY_FILE" "$tmp/body.md"
  labels="$LABELS_IN"
else
  # Una sola llamada. Si falla, exit 2: la PR puede estar bien y no lo sabemos.
  if ! $GH_API "repos/${REPO}/pulls/${PR}" > "$tmp/pr.json" 2>"$tmp/err"; then
    echo "check-pr-tldr: no se pudo leer ${REPO}#${PR}: $(tr -d '\n' < "$tmp/err" | cut -c1-160)" >&2
    exit 2
  fi
  python3 - "$tmp/pr.json" "$tmp/body.md" > "$tmp/labels" <<'PY' || { echo "check-pr-tldr: respuesta de la API ilegible" >&2; exit 2; }
import json, sys
d = json.load(open(sys.argv[1]))
open(sys.argv[2], "w", encoding="utf-8").write(d.get("body") or "")
print(",".join(l["name"] for l in (d.get("labels") or [])))
print(((d.get("base") or {}).get("ref")) or "")
print(((d.get("head") or {}).get("ref")) or "")
PY
  labels="$(sed -n 1p "$tmp/labels")"
  BASE_REF="$(sed -n 2p "$tmp/labels")"
  HEAD_REF="$(sed -n 3p "$tmp/labels")"
fi

promo=0
if [ "$PROMOTION" = 1 ] && [ -n "$BASE_REF" ] && [ "$BASE_REF" = "$PROTECTED" ] && [ "$HEAD_REF" = "$INTEGRATION" ]; then
  promo=1
fi

case ",${labels}," in
  *",${LABEL},"*) ;;
  *)
    if [ "$promo" != 1 ]; then
      echo "OK  ${REPO}#${PR} no lleva la marca '${LABEL}': la integra un agente bajo sus puertas, no se juzga su TL;DR."; exit 0
    fi
    ;;
esac

python3 - "$tmp/body.md" "$PR" "$REPO" "$promo" <<'PY'
import re, sys

body = open(sys.argv[1], encoding="utf-8").read()
pr, repo, promo = sys.argv[2], sys.argv[3], sys.argv[4] == "1"
problems = []

heads = [(m.start(), m.group(1).strip()) for m in re.finditer(r"^##\s+(.*)$", body, re.M)]
tl = next((i for i, (_, h) in enumerate(heads) if h.upper().replace(" ", "") == "TL;DR"), None)

if tl is None:
    problems.append("1. falta la seccion '## TL;DR': la marca dice que la lee una persona y no hay nada escrito para ella")
    section = ""
else:
    if tl != 0:
        problems.append("2. '## TL;DR' no es la primera seccion (va la %d.ª, detras de '%s')" % (tl + 1, heads[0][1]))
    start = heads[tl][0]
    end = heads[tl + 1][0] if tl + 1 < len(heads) else len(body)
    section = body[start:end]
    section = section.split("\n", 1)[1] if "\n" in section else ""

if tl is not None:
    prose = re.sub(r"```.*?```", " ", section, flags=re.S)
    # Lo CITADO no cuenta: «ver abajo» entre comillas o en `codigo` es un ejemplo de lo que no se
    # hace, no un «ver abajo». Se descubrio con la primera PR que uso este control: explicaba la
    # regla y el control la denuncio por nombrarla.
    citas = re.compile(r'«[^»]*»' + r'|"[^"]*"' + r"|'[^']*'" + r'|`[^`]*`')
    prose_sin_citas = citas.sub(" ", prose)
    if len(re.sub(r"\s+", " ", prose).strip()) < 200:
        problems.append("3. el TL;DR tiene menos de 200 caracteres de texto: un titular no es un resumen")

    for pat, why in (
        (r"\bver (mas )?(abajo|arriba)\b", "«ver abajo/arriba»"),
        (r"\b(mas|más) (abajo|arriba)\b", "«mas abajo/arriba»"),
        (r"\bcomo (en|se dijo en) la (PR|issue)\b", "«como en la PR/issue»"),
        (r"\bdetalle en la seccion\b", "«detalle en la seccion»"),
    ):
        if re.search(pat, prose_sin_citas, re.I):
            problems.append("4. el TL;DR remite a otro sitio (%s): quien decide no deberia tener que buscarlo" % why)
            break

    for m in re.finditer(r"(ADR[- ]?\d+|decisi[oó]n\s+D\d+|\bD\d{1,3}\b|#\d{1,5})", prose):
        line = prose[prose.rfind("\n", 0, m.start()) + 1: prose.find("\n", m.end()) if prose.find("\n", m.end()) != -1 else len(prose)]
        if "http" not in line:
            problems.append("5. el TL;DR cita '%s' sin traerlo: o se escribe ahi lo que hace falta, o se enlaza" % m.group(1))
            break

    cmd = re.search(r"gh pr\s+merge\s+(\d+)\s+--repo\s+([\w.-]+/[\w.-]+)", section)
    if not cmd:
        problems.append("6. el TL;DR no trae el comando de merge completo: su «si» es un comando, no un clic en la caja")
    elif cmd.group(1) != pr or cmd.group(2).lower() != repo.lower():
        problems.append("6. el comando del TL;DR mergea %s#%s, no esta PR (%s#%s)" % (cmd.group(2), cmd.group(1), repo, pr))

if promo and tl is not None:
    # Las reglas del resumen de release (antes, un linter aparte que no coincidia con este).
    FIELDS = ["Qué notarán los usuarios", "Qué puede salir mal y cómo se deshace",
              "Decisiones tuyas que van dentro", "Qué NO se ha comprobado"]
    for f in FIELDS:
        fm = re.search(r"\*\*" + re.escape(f) + r":\*\*[ \t]*(.*)", prose)
        if not fm:
            problems.append("7. promocion: falta el campo '%s'" % f)
        elif not fm.group(1).strip() or re.fullmatch(r"<.*>", fm.group(1).strip()):
            problems.append("7. promocion: el campo '%s' esta vacio o es el texto de la plantilla" % f)
    if "`" in prose:
        problems.append("8. promocion: codigo en linea en el TL;DR (%s): se dice por su efecto"
                        % ", ".join(sorted(set(re.findall(r"`[^`]*`", prose)))[:3]))
    paths = re.findall(r"(?<![\w/])(?:[\w.-]+/)+[\w.-]+\.(?:sh|json|ya?ml|md|py|ts|js)\b", prose)
    if paths:
        problems.append("8. promocion: rutas de ficheros en el TL;DR (%s)" % ", ".join(sorted(set(paths))[:3]))
    cmds = [ln.strip() for b in re.findall(r"```bash\n(.*?)```", section, re.S) for ln in b.splitlines()
            if ln.strip().startswith("gh pr merge")]
    if not cmds:
        problems.append("9. promocion: no hay 'gh pr merge' en un bloque bash")
    else:
        # que sea ESTA PR ya lo juzga la regla 6; aqui, la forma exacta
        if not re.fullmatch(r"gh pr merge (\d+) --repo ([\w.-]+/[\w.-]+) --merge", cmds[-1]):
            problems.append("9. promocion: el comando tiene que ser exactamente 'gh pr merge <n> --repo <owner>/<name> --merge' (hay: %s)" % cmds[-1])

for p in problems:
    print("FAIL  " + p)
print("----------------------------------------")
print("%s#%s %s, %d violacion(es)." % (repo, pr, "promocion" if promo else "marcada", len(problems)))
sys.exit(1 if problems else 0)
PY
