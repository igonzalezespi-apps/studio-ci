#!/usr/bin/env bash
# context-budget.sh — lo que Claude Code carga en cada sesion tiene un presupuesto, y la
# configuracion del repo que decide QUE se carga tiene que resolver a algo que existe.
#
# POR QUE EXISTE. Las reglas que el modelo lee al arrancar (CLAUDE.md, estilo de salida,
# contrato, descripciones de skills y agentes) crecen solas: cada correccion añade un parrafo
# con su fecha y nadie quita el anterior. Medido en la flota: un CLAUDE.md que llego a
# multiplicarse por diecisiete, y que se paga en CADA peticion de CADA sesion. Y la configuracion
# falla en silencio: un `outputStyle` que no resuelve cae a Default sin avisar, y un
# marketplace declarado sin `ref` sigue la rama por defecto del remoto, no lo publicado.
#
# OCHO comprobaciones, cada una con su nombre (el que sale entre corchetes):
#
#   size          limites por fichero, en bytes o en caracteres (CLAUDE.md, estilos, contrato)
#   descriptions  `description` (+ `when_to_use`) de cada skill, comando y agente <= N
#                 caracteres, y la suma del listado de skills de cada plugin <= M
#   dated         parrafos fechados o notas de «antes decia» en los ficheros de reglas
#   marketplace   el marketplace canonico se declara con su ruta canonica y con `ref`; la
#                 ruta antigua no aparece en ajustes ni workflows
#   output-style  `outputStyle` resuelve a un estilo que existe (y su plugin esta habilitado),
#                 con el nombre EXACTO que usa Claude Code: distingue mayusculas, y el `name:`
#                 del frontmatter sustituye al nombre del fichero; si la configuracion fija
#                 `output_style_expected`, es ese y no otro
#   user-keys     ninguna clave personal en el settings versionado del repo
#   agents        cada agente declara `model` y `effort`, y ninguno de solo lectura lleva
#                 `memory` (que concede Read/Write/Edit por su cuenta)
#   pact          si el repo usa el tablero, exactamente una linea del pacto en CLAUDE.md y
#                 ninguna copia. Lo decide `pact.required` o, sin el, lo versionado (no solo
#                 un `TASKS.md` en disco, que los consumidores ignoran en git)
#
# Las tres primeras son de PRESUPUESTO: la etiqueta de aprobacion (por defecto
# `presupuesto-contexto-aprobado`, que pone una persona) las deja pasar sin ocultarlas. Las
# otras cinco son de CONFIGURACION: una etiqueta no hace que un estilo inexistente exista.
#
# Uso:
#   context-budget.sh [--root DIR] [--config FICHERO] [--mode enforce|warn]
#                     [--labels "a,b"] [--approval-label ETIQUETA]
#                     [--marketplaces-dir DIR] [--annotations] [--staged] [--quiet]
#
#   --root              raiz del repo a revisar (por defecto, el directorio actual)
#   --config            JSON de configuracion; por defecto `.github/context-budget.json` o
#                       `.context-budget.json` si existen, y si no, los valores de fabrica
#   --mode              enforce (falla) o warn (solo avisa); manda sobre el `mode` del JSON
#   --labels            etiquetas de la PR, separadas por comas
#   --approval-label    etiqueta que aprueba un exceso de presupuesto
#   --marketplaces-dir  copia local de los marketplaces (p. ej. ~/.claude/plugins/marketplaces)
#                       para comprobar que el estilo de un plugin existe de verdad
#   --annotations       ademas, lineas `::error`/`::warning` para GitHub Actions
#   --staged            mide lo que se va a commitear: los ficheros del indice de git con el
#                       contenido añadido, no el arbol de trabajo. Lo que no esta en el indice
#                       (sin añadir, o ignorado como `settings.local.json` o `TASKS.md`) no
#                       existe, como en el checkout de CI. Exige que --root sea la raiz de un
#                       repo git
#   --quiet             solo hallazgos: nada si no hay ninguno; si los hay, sus lineas
#                       (FAIL, WARN, APROB) y el resumen, sin las lineas OK. Los errores de
#                       medida (exit 2) salen siempre
#
# Como pre-commit (un repo sin CI): en `.githooks/pre-commit`,
#   exec bash ruta/a/context-budget.sh --root "$(git rev-parse --show-toplevel)" --staged --quiet
#
# Salida: una linea por hallazgo y un resumen «context-budget: N violacion(es), ...».
# Exit 0 si no hay violaciones (los avisos no cuentan), 1 si hay, 2 si no se puede medir
# (sin python3, configuracion ilegible, argumento desconocido): no saber no es estar limpio.
#
# Sin dependencias fuera de bash y python3 (stdlib): el frontmatter se lee con un lector
# propio y tolerante, porque el de las skills reales no siempre es YAML valido (dos puntos sin
# comillas en una descripcion) y Claude Code las carga igual.
set -uo pipefail

case "${1:-}" in
  -h | --help) sed -n '/^# Uso:/,/^# Salida/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac
command -v python3 > /dev/null 2>&1 || { echo "context-budget: falta python3" >&2; exit 2; }

exec python3 - "$@" <<'PY'
import io
import json
import os
import re
import subprocess
import sys

# ---------------------------------------------------------------------------------------------
# Valores de fabrica. Un JSON de configuracion los sustituye CLAVE A CLAVE (una lista entera
# sustituye a la lista entera: asi nadie hereda un limite que no ve escrito).
# ---------------------------------------------------------------------------------------------
DEFAULTS = {
    "mode": "enforce",
    "limits": [
        {"glob": "CLAUDE.md", "max_bytes": 3000},
        {"glob": ".claude/CLAUDE.md", "max_bytes": 3000},
        {"glob": "**/output-styles/*.md", "max_bytes": 5000},
        {"glob": "**/contract-core.md", "max_chars": 4000},
    ],
    "description_max_chars": 250,
    "plugin_description_sum_max_chars": 6000,
    # Lo que suma el listado: skills y comandos que el modelo puede invocar. Los agentes tienen
    # su propio limite por pieza pero no entran en la suma (van en otro listado).
    "plugin_description_sum_kinds": ["skills", "commands"],
    "dated_globs": ["CLAUDE.md", "**/CLAUDE.md", ".claude/rules/**/*.md", "**/contract-core.md"],
    "marketplace": {
        "repo": "igonzalezespi-apps/claude-plugins",
        "ref": "main",
        "legacy_repos": ["igonzalezespi/claude-plugins"],
    },
    # Vacio = no se exige ninguno. Con valor, el settings versionado tiene que declarar ESE.
    "output_style_expected": "",
    "forbidden_settings_keys": ["model", "effortLevel", "autoCompactWindow"],
    "allowed_plugin_marketplaces": [],
    "pact": {
        # true: aplica siempre; false: no aplica; null: se deduce (ver `pact_applies`).
        "required": None,
        "plugin": "tablero",
        "tasks_file": "TASKS.md",
        "marker": "contrato TASKS v2",
        "aliases": ["pacto tablero", "tablero pact"],
        "copy_globs": ["**/CLAUDE.md", "CLAUDE.local.md", "**/AGENTS.md", ".claude/rules/**/*.md"],
    },
    "warn_checks": [],
    "skip_checks": [],
    "exclude": [
        "**/node_modules/**",
        "**/.git/**",
        ".claude/worktrees/**",
        "**/fixtures/**",
        "**/tests/**",
        "**/test/**",
        "**/archive/**",
    ],
}

CHECKS = ["size", "descriptions", "dated", "marketplace", "output-style", "user-keys", "agents", "pact"]
BUDGET_CHECKS = {"size", "descriptions", "dated"}  # las que la etiqueta puede aprobar
# Los integrados de Claude Code 2.1.286, con sus mayusculas (ademas de «default»).
BUILTIN_STYLES = {"Proactive", "Concise", "Explanatory", "Learning"}
WRITE_TOOLS = {"Write", "Edit", "MultiEdit", "NotebookEdit"}
ALLOW_MARK = "context-budget: allow"


def die(msg):
    print("context-budget: " + msg, file=sys.stderr)
    sys.exit(2)


# Un fallo interno NO puede salir con 1: se leeria como «hay violaciones» (o, peor, se
# aprenderia a ignorarlo). Sale con 2, que es «no se pudo medir», y con la traza.
def _crash(exc_type, exc, tb):
    import traceback
    sys.stdout.flush()
    traceback.print_exception(exc_type, exc, tb)
    print("context-budget: error interno (%s): no se pudo medir" % exc_type.__name__, file=sys.stderr)
    sys.stderr.flush()
    os._exit(2)


sys.excepthook = _crash


# ---------------------------------------------------------------------------------------------
# Argumentos
# ---------------------------------------------------------------------------------------------
args = sys.argv[1:]
opt = {"root": ".", "config": "", "mode": "", "labels": "", "approval": "presupuesto-contexto-aprobado",
       "mkt_dir": "", "annotations": False, "staged": False, "quiet": False}
i = 0
while i < len(args):
    a = args[i]
    flag_map = {"--root": "root", "--config": "config", "--mode": "mode", "--labels": "labels",
                "--approval-label": "approval", "--marketplaces-dir": "mkt_dir"}
    bool_map = {"--annotations": "annotations", "--staged": "staged", "--quiet": "quiet"}
    if a in flag_map:
        if i + 1 >= len(args):
            die("falta valor para " + a)
        opt[flag_map[a]] = args[i + 1]
        i += 2
    elif a in bool_map:
        opt[bool_map[a]] = True
        i += 1
    else:
        die("argumento desconocido '%s'" % a)

ROOT = os.path.abspath(opt["root"])
if not os.path.isdir(ROOT):
    die("no existe el directorio %s" % ROOT)


# ---------------------------------------------------------------------------------------------
# De donde se lee: el arbol de trabajo (por defecto) o, con `--staged`, el indice de git.
#
# POR QUE `--staged`. Como pre-commit, medir el disco se equivoca en los dos sentidos: un
# CLAUDE.md demasiado grande y SIN añadir bloquea un commit que no lo toca, y uno que esta bien
# en disco deja pasar el indice que no lo esta. Con `--staged` cada fichero se lee del indice
# (`git cat-file`), que es lo que el commit va a guardar, y lo que no esta en el se ignora: la
# misma vista que tendra el checkout de CI despues del push. Git exporta `GIT_INDEX_FILE` al
# hook, asi que `git commit -a` y `git commit -- ruta` (que usan un indice temporal) se miden
# tal cual.
# ---------------------------------------------------------------------------------------------
def _decode_text(raw):
    # Lo mismo que `open(..., encoding="utf-8", errors="replace").read()`, saltos de linea
    # universales incluidos: las dos fuentes miden el mismo texto igual.
    return io.TextIOWrapper(io.BytesIO(raw), encoding="utf-8", errors="replace").read()


def git_toplevel():
    """La raiz del repo git si ROOT lo es; None si no es un repo o ROOT es un subdirectorio."""
    try:
        top = subprocess.run(["git", "-C", ROOT, "rev-parse", "--show-toplevel"],
                             capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return None
    return top if top and os.path.realpath(top) == os.path.realpath(ROOT) else None


class TreeSource:
    """El disco. Una ruta relativa cuelga de ROOT; una absoluta (la copia de los marketplaces)
    se lee tal cual."""
    where = "en disco"

    def _p(self, rel):
        return os.path.join(ROOT, rel)

    def isfile(self, rel):
        return os.path.isfile(self._p(rel))

    def isdir(self, rel):
        return os.path.isdir(self._p(rel))

    def listdir(self, rel):
        try:
            return sorted(os.listdir(self._p(rel)))
        except OSError:
            return []

    def read_bytes(self, rel):
        with open(self._p(rel), "rb") as fh:
            return fh.read()


class IndexSource:
    """El indice de git (`--staged`): solo las entradas en la etapa 0 y sin submodulos; cada
    blob se lee por su SHA. Los enlaces simbolicos (de un fichero o de un directorio de la ruta)
    se siguen DENTRO del indice; si llevan fuera de el, lo que apuntan no existe, como en el
    checkout de CI."""
    where = "en el indice"

    def __init__(self):
        try:
            raw = subprocess.run(["git", "-C", ROOT, "ls-files", "-z", "--cached", "--stage"],
                                 capture_output=True, check=True).stdout
        except (OSError, subprocess.CalledProcessError) as exc:
            die("--staged: no se pudo leer el indice de git (%s)" % exc)
        self.entries = {}
        for rec in raw.split(b"\0"):
            if not rec or b"\t" not in rec:
                continue
            meta, path = rec.split(b"\t", 1)
            mode, sha, stage = meta.decode().split(" ")
            if stage != "0" or mode == "160000":
                continue  # sin resolver (el commit no sale igual) o submodulo (no es un fichero)
            self.entries[path.decode("utf-8", "replace")] = (mode, sha)
        self._blobs = {}

    @staticmethod
    def _norm(rel):
        rel = os.path.normpath(rel).replace(os.sep, "/") if rel else ""
        return "" if rel == "." else rel

    def _blob(self, sha):
        if sha not in self._blobs:
            try:
                self._blobs[sha] = subprocess.run(["git", "-C", ROOT, "cat-file", "blob", sha],
                                                  capture_output=True, check=True).stdout
            except (OSError, subprocess.CalledProcessError) as exc:
                die("--staged: no se pudo leer el blob %s del indice (%s)" % (sha, exc))
        return self._blobs[sha]

    def _real(self, rel):
        """La ruta del indice tras seguir los enlaces simbolicos de cualquier tramo de `rel`;
        None si sale del repo o hay un ciclo."""
        rel = self._norm(rel)
        for _ in range(16):
            if os.path.isabs(rel) or rel == ".." or rel.startswith("../"):
                return None
            parts = rel.split("/") if rel else []
            for k in range(1, len(parts) + 1):
                head = "/".join(parts[:k])
                ent = self.entries.get(head)
                if ent is not None and ent[0] == "120000":
                    target = self._blob(ent[1]).decode("utf-8", "replace")
                    if os.path.isabs(target):
                        return None
                    rel = self._norm(os.path.join(os.path.dirname(head), target, *parts[k:]))
                    break
            else:
                return rel
        return None

    def isfile(self, rel):
        return self._real(rel) in self.entries

    def _prefix(self, rel):
        real = self._real(rel)
        return None if real is None else (real + "/" if real else "")

    def isdir(self, rel):
        prefix = self._prefix(rel)
        return prefix is not None and any(p.startswith(prefix) for p in self.entries)

    def listdir(self, rel):
        prefix = self._prefix(rel)
        if prefix is None:
            return []
        return sorted({p[len(prefix):].split("/", 1)[0] for p in self.entries if p.startswith(prefix)})

    def read_bytes(self, rel):
        real = self._real(rel)
        if real not in self.entries:
            raise FileNotFoundError(rel)
        return self._blob(self.entries[real][1])


if opt["staged"]:
    if git_toplevel() is None:
        die("--staged necesita que --root (%s) sea la raiz de un repo git" % ROOT)
    SRC = IndexSource()
else:
    SRC = TreeSource()
DISK = TreeSource()

cfg = json.loads(json.dumps(DEFAULTS))
cfg_path = opt["config"]
if not cfg_path:
    for cand in (".github/context-budget.json", ".context-budget.json"):
        if SRC.isfile(cand):
            cfg_path = os.path.join(ROOT, cand)
            break
elif not os.path.isabs(cfg_path) and not os.path.isfile(cfg_path):
    cfg_path = os.path.join(ROOT, cfg_path)
if cfg_path:
    # Con `--staged`, la configuracion del repo tambien es la del indice; un `--config` que no
    # esta en el (fuera del repo, o sin añadir) se lee del disco, porque lo ha nombrado alguien.
    cfg_rel = os.path.relpath(os.path.abspath(cfg_path), ROOT)
    inside = cfg_rel != ".." and not cfg_rel.startswith("../")
    cfg_src = SRC if inside and SRC.isfile(cfg_rel) else DISK
    try:
        # `decode` estricto, como el `open(..., encoding="utf-8")` de siempre: un JSON que no
        # es UTF-8 es ilegible, no se arregla con caracteres de sustitucion.
        raw_cfg = cfg_src.read_bytes(cfg_rel if cfg_src is SRC else os.path.abspath(cfg_path))
        user_cfg = json.loads(raw_cfg.decode("utf-8"))
    except (OSError, ValueError) as exc:
        die("configuracion ilegible (%s): %s" % (cfg_path, exc))
    if not isinstance(user_cfg, dict):
        die("la configuracion (%s) no es un objeto JSON" % cfg_path)
    unknown = sorted(k for k in user_cfg if k not in DEFAULTS and not k.startswith("_"))
    if unknown:
        die("clave(s) desconocida(s) en %s: %s" % (cfg_path, ", ".join(unknown)))
    for k, v in user_cfg.items():
        if k.startswith("_"):
            continue  # comentarios: "_por_que": "..."
        if isinstance(DEFAULTS[k], dict) and isinstance(v, dict):
            merged = dict(cfg[k])
            merged.update(v)
            cfg[k] = merged
        else:
            cfg[k] = v

for rule in cfg["limits"] if isinstance(cfg["limits"], list) else [None]:
    if not isinstance(rule, dict) or not (rule.get("glob") or rule.get("path")) \
            or not isinstance(rule.get("max_bytes", rule.get("max_chars")), int):
        die("cada limite es {\"glob\": ..., \"max_bytes\"|\"max_chars\": entero}; no vale %s" % json.dumps(rule))
for key in ("warn_checks", "skip_checks", "exclude", "dated_globs", "forbidden_settings_keys",
            "allowed_plugin_marketplaces", "plugin_description_sum_kinds"):
    if not isinstance(cfg[key], list):
        die("'%s' tiene que ser una lista" % key)
# `is None`/bool y no `in (None, True, False)`: en Python 0 == False y 1 == True.
_req = cfg["pact"].get("required") if isinstance(cfg["pact"], dict) else None
if not (_req is None or isinstance(_req, bool)):
    die("'pact.required' tiene que ser true, false o no estar; no vale %s" % json.dumps(_req))

MODE = opt["mode"] or cfg.get("mode") or "enforce"
if MODE not in ("enforce", "warn"):
    die("modo desconocido '%s' (enforce o warn)" % MODE)
for name in list(cfg["warn_checks"]) + list(cfg["skip_checks"]):
    if name not in CHECKS:
        die("comprobacion desconocida '%s' (validas: %s)" % (name, ", ".join(CHECKS)))
LABELS = {x.strip() for x in opt["labels"].split(",") if x.strip()}
APPROVED = bool(opt["approval"]) and opt["approval"] in LABELS


# ---------------------------------------------------------------------------------------------
# Globs con `**` de verdad: `*` no cruza `/`, `**/` cruza cero o mas directorios.
# ---------------------------------------------------------------------------------------------
_glob_cache = {}


def glob_re(pattern):
    if pattern in _glob_cache:
        return _glob_cache[pattern]
    out, j = "", 0
    while j < len(pattern):
        c = pattern[j]
        if pattern.startswith("**/", j):
            out += "(?:.*/)?"
            j += 3
        elif pattern.startswith("**", j):
            out += ".*"
            j += 2
        elif c == "*":
            out += "[^/]*"
            j += 1
        elif c == "?":
            out += "[^/]"
            j += 1
        else:
            out += re.escape(c)
            j += 1
    rx = re.compile("^" + out + "$")
    _glob_cache[pattern] = rx
    return rx


def matches(path, patterns):
    return any(glob_re(p).match(path) for p in patterns)


# ---------------------------------------------------------------------------------------------
# Ficheros: los de git (versionados + nuevos no ignorados) si ROOT es un repo; si no, el arbol.
# Con `--staged`, solo los del indice.
# ---------------------------------------------------------------------------------------------
def list_files():
    if opt["staged"]:
        return [f for f in sorted(SRC.entries) if SRC.isfile(f) and not matches(f, cfg["exclude"])]
    files = None
    try:
        if git_toplevel() is not None:
            raw = subprocess.run(["git", "-C", ROOT, "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
                                 capture_output=True, check=True).stdout
            files = sorted({p for p in raw.decode("utf-8", "replace").split("\0") if p})
    except (OSError, subprocess.CalledProcessError):
        files = None
    if files is None:
        files = []
        for d, dirs, names in os.walk(ROOT):
            rel_d = os.path.relpath(d, ROOT)
            dirs[:] = [x for x in dirs if x not in (".git", "node_modules")
                       and os.path.normpath(os.path.join(rel_d, x)) != os.path.normpath(".claude/worktrees")]
            for n in names:
                files.append(os.path.normpath(os.path.join(rel_d, n)).replace(os.sep, "/"))
        files.sort()
    return [f for f in files if os.path.isfile(os.path.join(ROOT, f)) and not matches(f, cfg["exclude"])]


FILES = list_files()


def read_text(rel):
    return _decode_text(SRC.read_bytes(rel))


def read_bytes(rel):
    return SRC.read_bytes(rel)


# ---------------------------------------------------------------------------------------------
# Frontmatter tolerante: claves de primer nivel, escalares entre comillas o planos (con
# continuacion indentada), bloques `>`/`|` y listas `[a, b]` o `- a`. Devuelve (dict, lineas)
# donde lineas[clave] es el numero de linea (1-based) en el fichero.
# ---------------------------------------------------------------------------------------------
def unquote(v):
    if len(v) >= 2 and v[0] == v[-1] == '"':
        try:
            return json.loads(v)
        except ValueError:
            return v[1:-1]
    if len(v) >= 2 and v[0] == v[-1] == "'":
        return v[1:-1].replace("''", "'")
    return v


def parse_frontmatter(text):
    lines = text.split("\n")
    if not lines or lines[0].strip() != "---":
        return None, {}
    body = []
    for ln in lines[1:]:
        if ln.strip() == "---":
            break
        body.append(ln)
    else:
        return None, {}
    data, where, k = {}, {}, 0
    while k < len(body):
        m = re.match(r"^([A-Za-z0-9_-]+):(?:[ \t]+(.*)|[ \t]*)$", body[k])
        if not m:
            k += 1
            continue
        key, val, lineno = m.group(1), (m.group(2) or "").rstrip(), k + 2
        k += 1
        cont = []
        # continuacion: indentada, en blanco, o un `- item` en la columna 0 (YAML lo admite)
        while k < len(body) and (body[k][:1] in (" ", "\t") or body[k].strip() == "" or body[k].startswith("- ")):
            cont.append(body[k])
            k += 1
        while cont and cont[-1].strip() == "":
            cont.pop()
        if re.match(r"^[>|][+-]?[0-9]*$", val):
            parts = [c.strip() for c in cont]
            val = ("\n".join(parts) if val[0] == "|" else " ".join(p for p in parts if p)).strip()
        elif val == "" and cont and all(c.strip().startswith("- ") or c.strip() == "" for c in cont):
            val = [unquote(c.strip()[2:].strip()) for c in cont if c.strip()]
        else:
            if cont:
                val = " ".join([val] + [c.strip() for c in cont]).strip()
            if val.startswith("[") and val.endswith("]"):
                val = [unquote(x.strip()) for x in val[1:-1].split(",") if x.strip()]
            else:
                val = unquote(val)
        data[key] = val
        where[key] = lineno
    return data, where


def truthy(v):
    return isinstance(v, str) and v.strip().lower() in ("true", "yes", "on", "1")


def as_list(v):
    if v is None:
        return []
    if isinstance(v, list):
        return [str(x).strip() for x in v if str(x).strip()]
    return [x.strip() for x in str(v).split(",") if x.strip()]


# ---------------------------------------------------------------------------------------------
# Hallazgos
# ---------------------------------------------------------------------------------------------
findings = []  # (check, path, line, message)
examined = {c: 0 for c in CHECKS}
notes = {c: [] for c in CHECKS}


def add(check, path, line, msg):
    findings.append((check, path, line, msg))


def fmt_n(n):
    return "{:,}".format(n).replace(",", ".")


# --- raices de componentes: `.claude/` y cada plugin (`.claude-plugin/plugin.json`) ----------
def component_roots():
    roots = {}
    for f in FILES:
        if f.endswith(".claude-plugin/plugin.json"):
            base = f[: -len(".claude-plugin/plugin.json")].rstrip("/")
            name = os.path.basename(base) if base else os.path.basename(ROOT)
            try:
                name = json.loads(read_text(f)).get("name") or name
            except ValueError:
                pass
            roots[base] = name
    for f in FILES:
        m = re.match(r"^((?:.*/)?\.claude)/(?:skills|commands|agents)/", f)
        if m:
            roots.setdefault(m.group(1), "(proyecto) " + m.group(1))
    return roots


ROOTS = component_roots()


def components(kind):
    """(ruta, raiz) de cada skill, comando o agente, segun el `kind`."""
    out = []
    for base in ROOTS:
        prefix = (base + "/") if base else ""
        for f in FILES:
            if not f.startswith(prefix):
                continue
            rest = f[len(prefix):]
            if kind == "skills" and re.match(r"^skills/[^/]+/SKILL\.md$", rest):
                out.append((f, base))
            elif kind in ("commands", "agents") and rest.startswith(kind + "/") and rest.endswith(".md"):
                out.append((f, base))
    return sorted(set(out))


# ---------------------------------------------------------------------------------------------
# size — limites por fichero
# ---------------------------------------------------------------------------------------------
def check_size():
    for rule in cfg["limits"]:
        pat = rule.get("glob") or rule.get("path")
        for f in FILES:
            if not glob_re(pat).match(f):
                continue
            examined["size"] += 1
            if "max_chars" in rule:
                n, cap, unit = len(read_text(f)), int(rule["max_chars"]), "caracteres"
            else:
                n, cap, unit = len(read_bytes(f)), int(rule["max_bytes"]), "B"
            if n > cap:
                add("size", f, 0, "%s %s > %s %s (+%s)" % (fmt_n(n), unit, fmt_n(cap), unit, fmt_n(n - cap)))
            else:
                notes["size"].append("%s %s/%s %s" % (f, fmt_n(n), fmt_n(cap), unit))


# ---------------------------------------------------------------------------------------------
# descriptions — por pieza y suma del listado de cada plugin
# ---------------------------------------------------------------------------------------------
def check_descriptions():
    cap = int(cfg["description_max_chars"])
    sum_cap = int(cfg["plugin_description_sum_max_chars"])
    sum_kinds = set(cfg["plugin_description_sum_kinds"])
    sums, hidden = {}, 0
    for kind in ("skills", "commands", "agents"):
        for f, base in components(kind):
            data, where = parse_frontmatter(read_text(f))
            if data is None:
                continue
            if kind != "agents" and truthy(data.get("disable-model-invocation")):
                hidden += 1  # no entra en el listado del modelo: no cuesta contexto
                continue
            text = str(data.get("description") or "")
            if data.get("when_to_use"):
                text = (text + " " + str(data["when_to_use"])).strip()
            examined["descriptions"] += 1
            if kind in sum_kinds:
                sums[base] = sums.get(base, 0) + len(text)
            if len(text) > cap:
                add("descriptions", f, where.get("description", 0),
                    "description de %s caracteres > %s" % (fmt_n(len(text)), fmt_n(cap)))
    for base, total in sorted(sums.items()):
        label = ROOTS.get(base, base)
        if total > sum_cap:
            add("descriptions", (base or ".") + "/", 0,
                "el listado de %s suma %s caracteres > %s" % (label, fmt_n(total), fmt_n(sum_cap)))
        else:
            notes["descriptions"].append("%s %s/%s" % (label, fmt_n(total), fmt_n(sum_cap)))
    if hidden:
        notes["descriptions"].append("%d con disable-model-invocation, fuera del listado" % hidden)


# ---------------------------------------------------------------------------------------------
# dated — parrafos fechados y notas de «antes decia»
# ---------------------------------------------------------------------------------------------
MONTHS_ES = "enero|febrero|marzo|abril|mayo|junio|julio|agosto|septiembre|setiembre|octubre|noviembre|diciembre"
DATED_PATTERNS = [
    (re.compile(r"\b(?:19|20)\d\d-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12]\d|3[01])\b"), "fecha"),
    (re.compile(r"\b(?:0?[1-9]|[12]\d|3[01])[-/.](?:0?[1-9]|1[0-2])[-/.](?:19|20)\d\d\b"), "fecha"),
    (re.compile(r"\b\d{1,2} de (?:%s)\b" % MONTHS_ES, re.I), "fecha"),
    (re.compile(r"\b(?:el|del|desde el|hasta el) (?:0?[1-9]|[12]\d|3[01])-(?:0[1-9]|1[0-2])\b", re.I), "fecha"),
    (re.compile(r"(?:^[\s>*_-]*|\()[*_]*(?:corregid[oa]|enmendad[oa]|corrected|amended)\b", re.I), "nota de correccion"),
    (re.compile(r"\b(?:esta|este) (?:l[ií]nea|regla|frase|p[aá]rrafo|punto|bullet|fichero) dec[ií]a\b", re.I), "«antes decia»"),
    (re.compile(r"\b(?:hasta (?:hoy|entonces|ahora)|antes)\b[^.]{0,40}\bdec[ií]a\b", re.I), "«antes decia»"),
    (re.compile(r"\b(?:this|the) (?:line|rule|bullet|sentence|paragraph|file) (?:said|used to say)\b", re.I), "«antes decia»"),
    (re.compile(r"\buntil (?:then|today)\b[^.]{0,40}\bsaid\b", re.I), "«antes decia»"),
]


def check_dated():
    per_file_cap = 8
    for f in FILES:
        if not matches(f, cfg["dated_globs"]):
            continue
        examined["dated"] += 1
        fence, hits = False, []
        for n, ln in enumerate(read_text(f).split("\n"), 1):
            if re.match(r"^\s*(```|~~~)", ln):
                fence = not fence
                continue
            if fence or ALLOW_MARK in ln:
                continue
            for rx, why in DATED_PATTERNS:
                m = rx.search(ln)
                if m:
                    hits.append((n, why, m.group(0)))
                    break
        for n, why, what in hits[:per_file_cap]:
            add("dated", f, n, "parrafo fechado (%s: «%s»): la historia va al mensaje del commit" % (why, what))
        if len(hits) > per_file_cap:
            add("dated", f, 0, "... y %d linea(s) fechada(s) mas en este fichero" % (len(hits) - per_file_cap))


# ---------------------------------------------------------------------------------------------
# Ajustes del repo
# ---------------------------------------------------------------------------------------------
SETTINGS_FILES = [".claude/settings.json", ".claude/settings.local.json"]


def load_settings(rel):
    """dict, o None si no existe. Un JSON roto es un hallazgo, no un exit 2."""
    if not SRC.isfile(rel):
        return None
    try:
        d = json.loads(SRC.read_bytes(rel).decode("utf-8"))
        return d if isinstance(d, dict) else {}
    except ValueError as exc:
        add("user-keys", rel, 0, "JSON ilegible: Claude Code lo ignora entero (%s)" % exc)
        return {}


SETTINGS = {rel: load_settings(rel) for rel in SETTINGS_FILES}


def repo_of(src):
    """owner/repo (minusculas) de una fuente de marketplace github o git; '' si no es de GitHub."""
    if not isinstance(src, dict):
        return ""
    if src.get("source") == "github" and isinstance(src.get("repo"), str):
        return src["repo"].strip().lower().removesuffix(".git")
    url = src.get("url") if isinstance(src.get("url"), str) else ""
    m = re.search(r"github\.com[:/]+([\w.-]+/[\w.-]+?)(?:\.git)?/?$", url.strip(), re.I)
    return m.group(1).lower() if m else ""


def repo_rx(repo):
    return re.compile(r"(?<![\w.-])" + re.escape(repo) + r"(?![\w-])", re.I)


def check_marketplace():
    mk = cfg["marketplace"]
    canon = (mk.get("repo") or "").lower()
    ref = mk.get("ref") or ""
    legacy = [x.lower() for x in mk.get("legacy_repos") or []]
    for rel, st in SETTINGS.items():
        if not st:
            continue
        mkts = st.get("extraKnownMarketplaces") or {}
        if not isinstance(mkts, dict):
            continue
        for name, entry in mkts.items():
            src = (entry or {}).get("source") if isinstance(entry, dict) else None
            repo = repo_of(src)
            examined["marketplace"] += 1
            if repo in legacy:
                add("marketplace", rel, 0, "extraKnownMarketplaces.%s apunta a la ruta antigua %s (canonica: %s)"
                    % (name, repo, canon))
            elif canon and repo == canon and ref:
                got = src.get("ref") if isinstance(src, dict) else None
                if got != ref:
                    add("marketplace", rel, 0, "extraKnownMarketplaces.%s sin \"ref\": \"%s\" (tiene %s): sin ref se "
                        "sigue la rama por defecto del remoto, no lo publicado" % (name, ref, json.dumps(got)))
    wf = [f for f in FILES if re.match(r"^\.github/workflows/[^/]+\.ya?ml$", f)]
    for f in wf:
        examined["marketplace"] += 1
        raw = read_text(f).split("\n")
        # une las continuaciones con `\` para leer un `git clone` partido en varias lineas
        logical, start, buf = [], 0, ""
        for n, ln in enumerate(raw, 1):
            if not buf:
                start = n
            buf = (buf + " " + ln.strip()) if buf else ln
            if ln.rstrip().endswith("\\"):
                buf = buf.rstrip().rstrip("\\")
                continue
            logical.append((start, buf))
            buf = ""
        if buf:
            logical.append((start, buf))
        for n, ln in logical:
            if ALLOW_MARK in ln:
                continue
            is_comment = ln.lstrip().startswith("#")
            for old in legacy:
                if repo_rx(old).search(ln) and not is_comment:
                    add("marketplace", f, n, "usa la ruta antigua %s (canonica: %s)" % (old, canon))
            if canon and ref and not is_comment and repo_rx(canon).search(ln) and re.search(r"\bgit\s+clone\b", ln):
                if not re.search(r"(?:--branch[ =]|\s-b\s+)[\"']?%s[\"']?(?:\s|$)" % re.escape(ref), ln):
                    add("marketplace", f, n, "clona %s sin --branch %s: valida contra la rama por defecto, no contra "
                        "lo publicado" % (canon, ref))
        for n, ln in enumerate(raw, 1):
            m = re.match(r"^(\s*)repository:\s*[\"']?([\w.-]+/[\w.-]+)[\"']?\s*(?:#.*)?$", ln)
            if not m or ALLOW_MARK in ln or m.group(2).lower() != canon or not ref:
                continue
            ind, block = len(m.group(1)), []
            for other in raw[max(0, n - 8): n + 8]:
                mm = re.match(r"^(\s*)ref:\s*[\"']?([^\"'#\s]+)", other)
                if mm and len(mm.group(1)) == ind:
                    block.append(mm.group(2))
            if ref not in block:
                add("marketplace", f, n, "checkout de %s sin ref: %s" % (canon, ref))


def enabled_plugins():
    names = {}
    for st in SETTINGS.values():
        if not st:
            continue
        ep = st.get("enabledPlugins") or {}
        if isinstance(ep, dict):
            for key, val in ep.items():
                if val and "@" in key:
                    plugin, mkt = key.rsplit("@", 1)
                    names.setdefault(plugin, set()).add(mkt)
    return names


def style_names_in(src, d):
    """Nombres de estilo de un directorio, como los registra Claude Code: el `name:` del
    frontmatter si lo hay y, si no, el nombre del fichero sin `.md`. Uno u otro, nunca los dos,
    y con sus mayusculas (ver `check_output_style`)."""
    out = set()
    if not src.isdir(d):
        return out
    for n in src.listdir(d):
        if not n.endswith(".md"):
            continue
        name = None
        try:
            data, _ = parse_frontmatter(_decode_text(src.read_bytes(os.path.join(d, n))))
            raw = data.get("name") if data else None
            # `name:` vacio o nulo en YAML: Claude Code cae al nombre del fichero
            if raw is not None and not (isinstance(raw, str) and raw.strip() in ("", "~", "null", "Null", "NULL")):
                name = str(raw)
        except OSError:
            pass
        out.add(name or n[:-3])
    return out


def plugin_style_dirs(src, pdir):
    dirs = [os.path.join(pdir, "output-styles")]
    pj = os.path.join(pdir, ".claude-plugin", "plugin.json")
    try:
        decl = json.loads(src.read_bytes(pj).decode("utf-8")).get("outputStyles")
        for d in as_list(decl) if not isinstance(decl, list) else decl:
            dirs.append(os.path.normpath(os.path.join(pdir, str(d))))
    except (OSError, ValueError, AttributeError):
        pass
    return dirs


def find_plugin_dir(plugin, mkts):
    """(fuente, directorio) del plugin: en ESTE repo (con la fuente del repo, que con `--staged`
    es el indice), o en la copia local del marketplace (siempre el disco)."""
    for base, name in ROOTS.items():
        if name == plugin and not name.startswith("(proyecto)"):
            return SRC, base
    if opt["mkt_dir"]:
        for mkt in sorted(mkts):
            mroot = os.path.join(os.path.abspath(os.path.expanduser(opt["mkt_dir"])), mkt)
            try:
                with open(os.path.join(mroot, ".claude-plugin", "marketplace.json"), encoding="utf-8") as fh:
                    for p in json.load(fh).get("plugins", []):
                        if p.get("name") == plugin and isinstance(p.get("source"), str):
                            return DISK, os.path.normpath(os.path.join(mroot, p["source"]))
            except (OSError, ValueError, AttributeError):
                pass
            cand = os.path.join(mroot, "plugins", plugin)
            if os.path.isdir(cand):
                return DISK, cand
    return None, None


def case_hint(name, candidates):
    """Si `name` solo existe con otras mayusculas, lo dice: es el error que no se ve."""
    same = sorted(c for c in candidates if c != name and c.lower() == name.lower())
    return (" (Claude Code distingue mayusculas: existe \"%s\")" % same[0]) if same else ""


# COMO RESUELVE CLAUDE CODE `outputStyle` (2.1.286, leido en el binario y probado en vivo).
# Junta los integrados y los de cada fuente en un objeto cuya clave es el nombre del estilo
# (`plugin:nombre` en los de plugin) y busca el valor de `outputStyle` por CLAVE EXACTA; si no
# esta, cae a Default sin decir nada. Asi que «Pinya» no encuentra `pinya.md`, «explanatory» no
# es el integrado «Explanatory», y un fichero con `name:` en el frontmatter solo se llama asi
# (`x.md` con `name: otro` no responde a «x»). Probado con `claude -p` en un sandbox: con
# `pinya.md`, «pinya» aplica el estilo y «Pinya» no. Cualquier variante de «default» acaba en
# Default, que es lo pedido: esa si vale.
def check_output_style():
    enabled = enabled_plugins()
    want = cfg.get("output_style_expected") or ""
    if want:
        st = SETTINGS.get(".claude/settings.json")
        got = st.get("outputStyle") if isinstance(st, dict) else None
        examined["output-style"] += 1
        if got != want:
            add("output-style", ".claude/settings.json", 0, "outputStyle %s, y el acordado es \"%s\""
                % (json.dumps(got) if got is not None else "sin declarar", want))
    for rel, st in SETTINGS.items():
        if not st or "outputStyle" not in st:
            continue
        style = st.get("outputStyle")
        examined["output-style"] += 1
        if not isinstance(style, str) or not style.strip():
            add("output-style", rel, 0, "outputStyle vacio o no es texto: cae a Default en silencio")
            continue
        s = style  # sin `strip`: Claude Code tampoco lo recorta
        if s.strip().lower() == "default" or s in BUILTIN_STYLES:
            notes["output-style"].append("%s: %s (integrado)" % (rel, s))
            continue
        if ":" in s:
            plugin, name = s.split(":", 1)
            if plugin not in enabled:
                add("output-style", rel, 0, "outputStyle \"%s\": el plugin %s no esta habilitado en los ajustes del "
                    "repo, y sin el el estilo cae a Default en silencio" % (s, plugin))
                continue
            psrc, pdir = find_plugin_dir(plugin, enabled[plugin])
            if pdir is None:
                notes["output-style"].append("%s: %s (plugin habilitado; el estilo no se puede ver sin una copia del "
                                             "marketplace)" % (rel, s))
                continue
            found = set()
            for d in plugin_style_dirs(psrc, pdir):
                found |= style_names_in(psrc, d)
            if name not in found:
                add("output-style", rel, 0, "outputStyle \"%s\": el plugin %s no trae el estilo %s (trae: %s)%s"
                    % (s, plugin, name, ", ".join(sorted(found)) or "ninguno", case_hint(name, found)))
            else:
                notes["output-style"].append("%s: %s (resuelve)" % (rel, s))
        else:
            project = style_names_in(SRC, ".claude/output-styles")
            if s in project:
                notes["output-style"].append("%s: %s (.claude/output-styles)" % (rel, s))
            else:
                add("output-style", rel, 0, "outputStyle \"%s\" no es un estilo integrado ni esta en "
                    ".claude/output-styles/: cae a Default en silencio%s" % (s, case_hint(s, project | BUILTIN_STYLES)))


def check_user_keys():
    rel = ".claude/settings.json"
    st = SETTINGS.get(rel)
    if st is None:
        return
    examined["user-keys"] += 1
    for key in cfg["forbidden_settings_keys"]:
        cur, ok = st, True
        for part in key.split("."):
            if isinstance(cur, dict) and part in cur:
                cur = cur[part]
            else:
                ok = False
                break
        if ok:
            add("user-keys", rel, 0, "\"%s\" es un ajuste personal: en el settings del repo pisa el de cada "
                "usuario (va en el suyo o en .claude/settings.local.json)" % key)
    declared = set((st.get("extraKnownMarketplaces") or {}).keys()) if isinstance(st.get("extraKnownMarketplaces"), dict) else set()
    declared |= set(cfg["allowed_plugin_marketplaces"])
    ep = st.get("enabledPlugins") or {}
    if isinstance(ep, dict):
        for key in sorted(ep):
            mkt = key.rsplit("@", 1)[1] if "@" in key else ""
            if mkt not in declared:
                add("user-keys", rel, 0, "enabledPlugins \"%s\": su marketplace no lo declara este repo, asi que es "
                    "un plugin del usuario" % key)


# ---------------------------------------------------------------------------------------------
# agents — model + effort declarados; sin memory en los de solo lectura
# ---------------------------------------------------------------------------------------------
def check_agents():
    for f, _ in components("agents"):
        data, where = parse_frontmatter(read_text(f))
        examined["agents"] += 1
        if data is None:
            add("agents", f, 1, "sin frontmatter: hereda modelo y esfuerzo de la sesion")
            continue
        model = str(data.get("model") or "").strip()
        if not model:
            add("agents", f, 1, "sin model: hereda el de la sesion principal")
        if not str(data.get("effort") or "").strip() and "haiku" not in model.lower():
            add("agents", f, 1, "sin effort: hereda el de la sesion principal")
        mem = str(data.get("memory") or "").strip().lower()
        if mem and mem not in ("none", "false", "no", "off"):
            tools = [t.split("(")[0].strip() for t in as_list(data.get("tools"))]
            denied = {t.split("(")[0].strip() for t in as_list(data.get("disallowedTools"))}
            read_only = (bool(tools) and "*" not in tools and not (set(tools) & WRITE_TOOLS)) or \
                        ({"Write", "Edit"} <= denied)
            if read_only:
                add("agents", f, where.get("memory", 1), "memory: %s en un agente de solo lectura: memory le concede "
                    "Read/Write/Edit por su cuenta" % mem)


# ---------------------------------------------------------------------------------------------
# pact — si el repo usa el tablero, una linea del pacto en CLAUDE.md y ninguna copia
# ---------------------------------------------------------------------------------------------
# Una entrada de lista (`- `, `* `, `+ `, `1. `), tambien dentro de una cita. En CLAUDE.md un
# alias solo cuenta como copia del pacto si encabeza una ENTRADA: las copias v1 reales son
# siempre una regla de la lista, y una frase que solo nombra el pacto (al contar que inyecta el
# contrato, p. ej.) no lo copia. En los demas ficheros cualquier linea cuenta, como antes: ahi
# el pacto no pinta nada, y una regla por ruta suele ir en prosa.
LIST_ITEM_RX = re.compile(r"^\s*(?:>\s*)*(?:[-*+]|\d+[.)])\s+")


def pact_line(ln, marker, alias_rx):
    """La linea es del pacto: lleva el marcador, o es una entrada de lista con un alias."""
    return bool(marker and marker in ln) or (bool(LIST_ITEM_RX.match(ln)) and any(r.search(ln) for r in alias_rx))


def pact_applies(pc, main, lines, marker, alias_rx):
    """(aplica, motivo). `pact.required` manda; sin el, se deduce del repo.

    POR QUE NO BASTA `TASKS.md`. Es un fichero local de cada maquina y los consumidores lo
    llevan en `.gitignore`: en el checkout de CI no existe nunca, y el check no actuaba. Por eso
    cuenta tambien lo VERSIONADO: el plugin del tablero habilitado en `.claude/settings.json`
    (no en `settings.local.json`, que es personal y tampoco llega a CI) o el pacto ya escrito en
    CLAUDE.md, para que una copia duplicada o v1 se vea aunque no haya `TASKS.md`. Con
    `--staged` tambien `TASKS.md` se busca en el indice: lo ignorado no cuenta, como en CI."""
    req = pc.get("required")
    if req is not None:
        return req, "pact.required es %s" % ("true" if req else "false")
    tasks = pc.get("tasks_file") or "TASKS.md"
    plugin = pc.get("plugin") or "tablero"
    why = []
    if SRC.isfile(tasks):
        why.append("%s %s" % (tasks, SRC.where))
    st = SETTINGS.get(".claude/settings.json")
    ep = st.get("enabledPlugins") if isinstance(st, dict) else None
    if isinstance(ep, dict):
        on = sorted(k for k, v in ep.items() if v and "@" in k and k.rsplit("@", 1)[0] == plugin)
        if on:
            why.append("%s habilitado en .claude/settings.json" % on[0])
    for n, ln in enumerate(lines, 1):
        if ALLOW_MARK not in ln and pact_line(ln, marker, alias_rx):
            why.append("%s:%d lleva el pacto" % (main, n))
            break
    if why:
        return True, ", ".join(why)
    return False, "sin %s: no aplica (tampoco hay %s habilitado ni el pacto en %s)" % (tasks, plugin, main)


def check_pact():
    pc = cfg["pact"]
    marker = pc.get("marker") or ""
    alias_rx = [re.compile(re.escape(a), re.I) for a in pc.get("aliases") or []]
    main = "CLAUDE.md" if SRC.isfile("CLAUDE.md") else ".claude/CLAUDE.md"
    has_main = SRC.isfile(main)
    lines = read_text(main).split("\n") if has_main else []
    applies, why = pact_applies(pc, main, lines, marker, alias_rx)
    if not applies:
        notes["pact"].append(why if why.startswith("sin ") else "no aplica: " + why)
        return
    examined["pact"] += 1
    notes["pact"].append("aplica: " + why)
    if not has_main:
        add("pact", "CLAUDE.md", 0, "no hay CLAUDE.md con la linea del pacto (aplica: %s)" % why)
        return
    marked = [n for n, ln in enumerate(lines, 1) if marker in ln]
    if len(marked) != 1:
        add("pact", main, marked[1] if len(marked) > 1 else 0,
            "%d linea(s) con «%s»: tiene que haber exactamente una (aplica: %s)" % (len(marked), marker, why))
    for n, ln in enumerate(lines, 1):
        if n not in marked and ALLOW_MARK not in ln and pact_line(ln, "", alias_rx):
            add("pact", main, n, "copia vieja del pacto fuera de la linea «%s»" % marker)
    for f in FILES:
        if f == main or not matches(f, pc.get("copy_globs") or []):
            continue
        for n, ln in enumerate(read_text(f).split("\n"), 1):
            if ALLOW_MARK in ln:
                continue
            if (marker and marker in ln) or any(r.search(ln) for r in alias_rx):
                add("pact", f, n, "otra copia del pacto: el texto vive solo en %s" % main)
                break


RUNNERS = {"size": check_size, "descriptions": check_descriptions, "dated": check_dated,
           "marketplace": check_marketplace, "output-style": check_output_style,
           "user-keys": check_user_keys, "agents": check_agents, "pact": check_pact}

for c in CHECKS:
    if c not in cfg["skip_checks"]:
        RUNNERS[c]()

# ---------------------------------------------------------------------------------------------
# Veredicto
# ---------------------------------------------------------------------------------------------
n_fail = n_warn = n_ok_label = 0
by_check = {c: [] for c in CHECKS}
for f in findings:
    by_check[f[0]].append(f)


def annot(kind, check, path, line, msg):
    if not opt["annotations"]:
        return
    loc = "file=%s" % path.rstrip("/") if path and not path.endswith("/") else ""
    if loc and line:
        loc += ",line=%d" % line
    clean = msg.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    print("::%s %stitle=context-budget [%s]::%s" % (kind, (loc + ",") if loc else "", check, clean))


# `--quiet`: solo las lineas de hallazgo (FAIL, WARN, APROB) y el resumen, y nada si no hay
# ninguno. Para un pre-commit: las lineas OK de cada commit son contexto que se paga en cada
# sesion que commitea. Los errores de medida van a stderr con exit 2 y no pasan por aqui.
QUIET = opt["quiet"]


def info(line):
    if not QUIET:
        print(line)


for c in CHECKS:
    if c in cfg["skip_checks"]:
        info("--    [%s] desactivada por la configuracion" % c)
        continue
    items = by_check[c]
    if not items:
        extra = "; ".join(notes[c][:6])
        if examined[c]:
            info("OK    [%s] %d revisado(s)%s" % (c, examined[c], (": " + extra) if extra else ""))
        else:
            info("--    [%s] %s" % (c, extra or "nada que revisar"))
        continue
    for check, path, line, msg in items:
        where = path + (":%d" % line if line else "")
        if MODE == "enforce" and c not in cfg["warn_checks"]:
            if c in BUDGET_CHECKS and APPROVED:
                n_ok_label += 1
                print("APROB [%s] %s: %s" % (c, where, msg))
                annot("warning", c, path, line, "aprobado por la etiqueta: " + msg)
            else:
                n_fail += 1
                print("FAIL  [%s] %s: %s" % (c, where, msg))
                annot("error", c, path, line, msg)
        else:
            n_warn += 1
            print("WARN  [%s] %s: %s" % (c, where, msg))
            annot("warning", c, path, line, msg)

if QUIET and not (n_fail or n_warn or n_ok_label):
    sys.exit(0)
info("----------------------------------------")
tail = ""
if n_ok_label:
    tail = ", %d aprobada(s) por la etiqueta '%s'" % (n_ok_label, opt["approval"])
print("context-budget: %d violacion(es), %d aviso(s)%s (modo %s, %d fichero(s) %s)."
      % (n_fail, n_warn, tail, MODE, len(FILES), "en el indice" if opt["staged"] else "en el arbol"))
if n_fail and not APPROVED and any(f[0] in BUDGET_CHECKS for f in findings):
    print("Un exceso de presupuesto (size, descriptions, dated) solo lo aprueba una persona, con la etiqueta '%s'."
          % opt["approval"])
sys.exit(1 if n_fail else 0)
PY
