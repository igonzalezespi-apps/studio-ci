#!/usr/bin/env bash
# La concurrencia de los workflows reutilizables, evaluada evento a evento.
#
# POR QUE EXISTE. En otro repositorio, 21 de 27 checks acabaron `cancelled` y Renovate automergeo
# 3 de 47 PRs: `opened` y `labeled` caian en el mismo grupo cancelable, uno mataba al otro sobre el
# MISMO commit y el `cancelled` se quedaba en la cabeza de la PR. Leer el YAML no basta para ver eso:
# hay que calcular el grupo y el `cancel-in-progress` que saldrian para cada evento. Esta suite lo
# hace con un evaluador pequeno de las expresiones de GitHub (solo lo que usan estos ficheros:
# `&&`, `||`, `!`, `==`, `!=`, `startsWith`, `contains`, `fromJSON`, `format`, rutas de propiedades)
# y comprueba las reglas:
#
#   1. un evento que no trae codigo nuevo (`labeled`, `unlabeled`, `edited`, `reopened`,
#      `ready_for_review`) nunca esta en un grupo que cancela, y su grupo es solo suyo;
#   2. `opened` y `synchronize` de una PR comparten grupo y cancelan: lo cancelado es un commit viejo;
#   3. push, schedule y workflow_dispatch no cancelan nunca;
#   4. el heartbeat no cancela nunca, y en una PR su grupo es solo suyo.
#   5. los workflows propios con `concurrency` de primer nivel (ci, guard-selftest,
#      detect-changes-selftest, pr-title-lint, pr-tldr) cumplen 1-3, y dos push a develop/main no
#      comparten grupo: cada commit de la rama principal tiene su CI.
#
# Y despues MUTA los ficheros (las dos "simplificaciones" que reintroducen el fallo) y exige que la
# suite los rechace: un test que no puede fallar no protege nada.
#
# Uso: bash .github/workflows/concurrency.test.sh
set -uo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

cat > "$TMP/reglas.py" <<'PY'
import copy, json, re, sys
import yaml

# ── evaluador ────────────────────────────────────────────────────────────────────────────────────
TOK = re.compile(r"\s*(?:(?P<str>'(?:[^']|'')*')|(?P<num>-?\d+(?:\.\d+)?)|(?P<op>&&|\|\||==|!=|!|\(|\)|,)|(?P<id>[A-Za-z_][A-Za-z0-9_.\-]*))")

def tokens(s):
    pos, out = 0, []
    s = s.strip()
    while pos < len(s):
        m = TOK.match(s, pos)
        if not m or m.end() == pos:
            raise SyntaxError(f"no entiendo la expresion en {s[pos:]!r}")
        pos = m.end()
        for k in ("str", "num", "op", "id"):
            if m.group(k) is not None:
                out.append((k, m.group(k)))
                break
    return out

def verdad(v):
    return not (v is None or v is False or v == 0 or v == "")

def texto(v):
    if v is None: return ""
    if v is True: return "true"
    if v is False: return "false"
    if isinstance(v, float) and v.is_integer(): return str(int(v))
    return str(v)

def igual(a, b):
    if isinstance(a, str) and isinstance(b, str):
        return a.lower() == b.lower()
    return a == b

def fmt(f, *args):
    out = re.sub(r"\{(\d+)\}", lambda m: texto(args[int(m.group(1))]), f.replace("{{", "\0").replace("}}", "\1"))
    return out.replace("\0", "{").replace("\1", "}")

FUNC = {
    "startswith": lambda a, b: texto(a).lower().startswith(texto(b).lower()),
    "contains": lambda a, b: any(igual(x, b) for x in a) if isinstance(a, list) else texto(b).lower() in texto(a).lower(),
    "fromjson": lambda s: json.loads(s),
    "format": fmt,
}

class Parser:
    def __init__(self, s, ctx):
        self.t, self.i, self.ctx = tokens(s), 0, ctx
    def ver(self):
        return self.t[self.i] if self.i < len(self.t) else (None, None)
    def toma(self, v=None):
        k, x = self.ver()
        if v is not None and x != v:
            raise SyntaxError(f"esperaba {v!r}, hay {x!r}")
        self.i += 1
        return k, x
    def todo(self):
        v = self.o()
        if self.i != len(self.t):
            raise SyntaxError(f"sobra {self.t[self.i:]}")
        return v
    def o(self):
        v = self.y()
        while self.ver()[1] == "||":
            self.toma(); d = self.y(); v = v if verdad(v) else d
        return v
    def y(self):
        v = self.cmp()
        while self.ver()[1] == "&&":
            self.toma(); d = self.cmp(); v = d if verdad(v) else v
        return v
    def cmp(self):
        v = self.no()
        while self.ver()[1] in ("==", "!="):
            op = self.toma()[1]; d = self.no()
            v = igual(v, d) if op == "==" else not igual(v, d)
        return v
    def no(self):
        if self.ver()[1] == "!":
            self.toma(); return not verdad(self.no())
        return self.prim()
    def prim(self):
        k, x = self.toma()
        if k == "str": return x[1:-1].replace("''", "'")
        if k == "num": return float(x)
        if x == "(":
            v = self.o(); self.toma(")"); return v
        if k == "id":
            if x in ("true", "false"): return x == "true"
            if x == "null": return None
            if self.ver()[1] == "(":
                self.toma("(")
                args = []
                if self.ver()[1] != ")":
                    args.append(self.o())
                    while self.ver()[1] == ",":
                        self.toma(); args.append(self.o())
                self.toma(")")
                return FUNC[x.lower()](*args)
            v = self.ctx
            for parte in x.split("."):
                v = v.get(parte) if isinstance(v, dict) else None
            return v
        raise SyntaxError(f"no esperaba {x!r}")

def trozos(s):
    """Parte una plantilla en texto y expresiones; un `}}` dentro de una cadena no cierra."""
    out, i = [], 0
    while True:
        j = s.find("${{", i)
        if j < 0:
            out.append(("txt", s[i:])); return out
        out.append(("txt", s[i:j]))
        k, comilla = j + 3, False
        while k < len(s):
            if s[k] == "'":
                comilla = not comilla
            elif not comilla and s.startswith("}}", k):
                break
            k += 1
        if k >= len(s):
            raise SyntaxError(f"`${{{{` sin cerrar en {s!r}")
        out.append(("expr", s[j + 3:k])); i = k + 2

def evalua(valor, ctx):
    if isinstance(valor, bool): return valor
    partes = [p for p in trozos(str(valor).strip()) if p != ("txt", "")]
    if len(partes) == 1 and partes[0][0] == "expr":
        return Parser(partes[0][1], ctx).todo()
    return "".join(x if k == "txt" else texto(Parser(x, ctx).todo()) for k, x in partes)

# ── contextos de los eventos ─────────────────────────────────────────────────────────────────────
def ctx(evento, accion=None, pr=7, run=1001, ref="refs/heads/develop"):
    ev = {}
    if accion: ev["action"] = accion
    if evento.startswith("pull_request"): ev["pull_request"] = {"number": pr}
    return {"github": {"event_name": evento, "event": ev, "repository": "acme/app", "run_id": run,
                       "run_attempt": 1, "ref": ref}}

SIN_CODIGO = ["labeled", "unlabeled", "edited", "reopened", "ready_for_review"]
CODIGO = ["opened", "synchronize"]

def concurrencia(doc):
    if doc.get("concurrency"):
        return doc["concurrency"]
    (job,) = doc["jobs"].values()
    return job["concurrency"]

def calcula(c, cx):
    return evalua(c["group"], cx), verdad(evalua(c.get("cancel-in-progress", False), cx))

def reglas_security(doc):
    fallos = []
    c = concurrencia(doc)
    def caso(nombre, cx):
        return nombre, *calcula(c, cx)
    # 1. sin codigo nuevo: no cancela y su grupo es solo suyo
    for a in SIN_CODIGO:
        n, g, can = caso(f"pull_request/{a}", ctx("pull_request", a, run=2000))
        if can: fallos.append(f"{n}: cancel-in-progress true")
        g2, _ = calcula(c, ctx("pull_request", a, run=2001))
        if g == g2: fallos.append(f"{n}: dos ejecuciones comparten grupo ({g})")
        for b in CODIGO:
            gb, _ = calcula(c, ctx("pull_request", b, run=3000))
            if g == gb: fallos.append(f"{n}: comparte grupo con {b} ({g})")
    # 2. opened/synchronize: mismo grupo por PR, cancela; PRs distintas no se tocan
    g_o, c_o = calcula(c, ctx("pull_request", "opened", run=1))
    g_s, c_s = calcula(c, ctx("pull_request", "synchronize", run=2))
    g_otra, _ = calcula(c, ctx("pull_request", "synchronize", pr=8, run=3))
    if g_o != g_s: fallos.append(f"opened y synchronize de la misma PR en grupos distintos ({g_o} / {g_s})")
    if not (c_o and c_s): fallos.append("opened/synchronize no cancelan la ejecucion vieja")
    if g_s == g_otra: fallos.append(f"dos PRs distintas comparten grupo ({g_s})")
    # 3. push, schedule, workflow_dispatch: nunca cancelan
    for ev in ("push", "schedule", "workflow_dispatch"):
        _, can = calcula(c, ctx(ev))
        if can: fallos.append(f"{ev}: cancel-in-progress true")
    return fallos

def reglas_heartbeat(doc):
    fallos = []
    c = concurrencia(doc)
    for ev, a in [("pull_request", x) for x in SIN_CODIGO + CODIGO] + [("schedule", None), ("workflow_dispatch", None)]:
        g, can = calcula(c, ctx(ev, a, run=4000))
        if can: fallos.append(f"heartbeat {ev}/{a}: cancel-in-progress true")
        if ev == "pull_request":
            g2, _ = calcula(c, ctx(ev, a, run=4001))
            if g == g2: fallos.append(f"heartbeat {ev}/{a}: dos ejecuciones comparten grupo ({g})")
    g1, _ = calcula(c, ctx("schedule", run=1))
    g2, _ = calcula(c, ctx("workflow_dispatch", run=2))
    if g1 != g2: fallos.append("heartbeat: schedule y workflow_dispatch no comparten grupo (dos pings a la vez)")
    return fallos

def reglas_workflow(doc):
    """Un workflow propio (no reutilizable) con `concurrency` de primer nivel: las reglas de security
    y, ademas, dos push a la misma rama no comparten grupo (GitHub descartaria el pendiente)."""
    fallos = reglas_security(doc)
    c = doc["concurrency"]
    for rama in ("refs/heads/develop", "refs/heads/main"):
        g1, _ = calcula(c, ctx("push", ref=rama, run=10))
        g2, _ = calcula(c, ctx("push", ref=rama, run=11))
        if g1 == g2: fallos.append(f"push a {rama}: dos commits comparten grupo ({g1}); el pendiente se descarta")
    return fallos

def carga(p):
    with open(p, encoding="utf-8") as fh:
        return yaml.safe_load(fh)

if __name__ == "__main__":
    modo, fichero = sys.argv[1], sys.argv[2]
    doc = carga(fichero)
    on = doc.get("on", doc.get(True))
    fallos = []
    if modo == "workflow":
        if not doc.get("concurrency"):
            fallos.append("sin `concurrency` de primer nivel")
        else:
            fallos += reglas_workflow(doc)
    else:
        if list((on or {}).keys()) != ["workflow_call"]:
            fallos.append(f"`on` debe ser solo workflow_call, es {list((on or {}).keys())}")
        fallos += reglas_security(doc) if modo == "security" else reglas_heartbeat(doc)
    for f in fallos:
        print(f"    - {f}")
    sys.exit(1 if fallos else 0)
PY

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
mal()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

# comprueba <modo> <fichero> <etiqueta> <exit-esperado>
comprueba() {
  local out rc=0
  out="$(python3 "$TMP/reglas.py" "$1" "$2" 2>&1)" || rc=$?
  if [ "$rc" -eq "$4" ]; then ok "$3"; else mal "$3 (exit $rc, esperaba $4)"; printf '%s\n' "$out"; fi
}

echo "== evaluador: casos conocidos =="
python3 - "$TMP" <<'PY' && ok "evaluador" || mal "evaluador"
import sys; sys.path.insert(0, sys.argv[1])
from reglas import evalua, ctx
c = ctx("pull_request", "labeled", pr=12, run=55)
casos = [
    ("${{ startsWith(github.event_name, 'pull_request') }}", True),
    ("${{ contains(fromJSON('[\"opened\",\"synchronize\"]'), github.event.action) }}", False),
    ("${{ github.event.action == 'LABELED' }}", True),
    ("x-${{ false && 'a' || format('r-{0}-{{x}}', github.run_id) }}", "x-r-55-{x}"),
    ("${{ !github.event.nada }}", True),
    ("${{ github.event.pull_request.number }}", 12.0),
]
malos = [(e, evalua(e, c), q) for e, q in casos if evalua(e, c) != q]
for m in malos: print("   ", m)
sys.exit(1 if malos else 0)
PY

echo "== los ficheros reales =="
comprueba security  "$HERE/security.yml"           "security.yml cumple las reglas de concurrencia" 0
comprueba heartbeat "$HERE/renovate-heartbeat.yml" "renovate-heartbeat.yml cumple las reglas de concurrencia" 0
# Los workflows propios con `concurrency` de primer nivel: solo cancelan lo que un commit nuevo dejo
# viejo, y nunca un push a develop/main.
for wf in ci guard-selftest detect-changes-selftest pr-title-lint pr-tldr; do
  comprueba workflow "$HERE/$wf.yml" "$wf.yml cumple las reglas de concurrencia" 0
done

echo "== mutantes: cada uno debe romper la suite =="
muta() { # muta <origen> <destino> <python que transforma el doc>
  python3 - "$1" "$2" "$3" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
(job,) = doc["jobs"].values()
c = job["concurrency"]
exec(sys.argv[3])
open(sys.argv[2], "w").write(yaml.safe_dump(doc, sort_keys=False))
PY
}
muta "$HERE/security.yml" "$TMP/m1.yml" 'c["cancel-in-progress"] = True'
comprueba security "$TMP/m1.yml" "mutante: cancel-in-progress siempre true" 1
muta "$HERE/security.yml" "$TMP/m2.yml" 'c["group"] = "studio-security-${{ github.repository }}-${{ github.event.pull_request.number || github.ref }}"'
comprueba security "$TMP/m2.yml" "mutante: grupo por PR para todos los eventos" 1
muta "$HERE/security.yml" "$TMP/m3.yml" 'c["cancel-in-progress"] = "${{ startsWith(github.event_name, \"pull_request\") }}".replace("\"", "\x27")'
comprueba security "$TMP/m3.yml" "mutante: cancela en cualquier evento de PR" 1
muta "$HERE/security.yml" "$TMP/m4.yml" 'c["group"] = "studio-security-${{ github.repository }}-${{ format(\x27run-{0}\x27, github.run_id) }}"'
comprueba security "$TMP/m4.yml" "mutante: opened y synchronize ya no comparten grupo" 1
muta "$HERE/renovate-heartbeat.yml" "$TMP/m5.yml" 'c["group"] = "studio-renovate-heartbeat-${{ github.repository }}"'
comprueba heartbeat "$TMP/m5.yml" "mutante: heartbeat de PR en el grupo de los pings" 1
muta "$HERE/renovate-heartbeat.yml" "$TMP/m6.yml" 'c["cancel-in-progress"] = True'
comprueba heartbeat "$TMP/m6.yml" "mutante: heartbeat que cancela" 1
muta "$HERE/security.yml" "$TMP/m7.yml" 'doc["on"] = {"workflow_call": doc.pop(True)["workflow_call"], "pull_request": None}'
comprueba security "$TMP/m7.yml" "mutante: el reutilizable tambien se dispara solo" 1

mutaw() { # mutaw <origen> <destino> <python que transforma el doc>: concurrency de primer nivel
  python3 - "$1" "$2" "$3" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
c = doc.get("concurrency") or {}
exec(sys.argv[3])
open(sys.argv[2], "w").write(yaml.safe_dump(doc, sort_keys=False))
PY
}
mutaw "$HERE/ci.yml" "$TMP/w1.yml" 'c["group"] = "${{ github.workflow }}-${{ github.ref }}"; c["cancel-in-progress"] = "${{ github.ref != \x27refs/heads/main\x27 }}"'
comprueba workflow "$TMP/w1.yml" "mutante: el grupo por ref de antes (cancela develop y el mismo commit)" 1
mutaw "$HERE/pr-tldr.yml" "$TMP/w2.yml" 'c["cancel-in-progress"] = True'
comprueba workflow "$TMP/w2.yml" "mutante: workflow que cancela en cualquier evento" 1
mutaw "$HERE/ci.yml" "$TMP/w3.yml" 'c["group"] = c["group"].replace("format(\x27run-{0}-{1}\x27, github.run_id, github.run_attempt)", "github.ref")'
comprueba workflow "$TMP/w3.yml" "mutante: push y eventos sin codigo agrupados por ref" 1
mutaw "$HERE/pr-tldr.yml" "$TMP/w4.yml" 'doc.pop("concurrency")'
comprueba workflow "$TMP/w4.yml" "mutante: workflow sin concurrency" 1

echo
echo "concurrency.test.sh: $PASS ok, $FAIL fallos"
[ "$FAIL" -eq 0 ]
