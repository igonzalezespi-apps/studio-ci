#!/usr/bin/env bash
# check.sh — higiene de los pins de GitHub Actions en `.github/workflows/*.yml`.
#
# Recorre cada linea `uses: <owner>/<repo>@<ref>  # <tag>`, resuelve el tag aguas arriba y falla
# si el pin no es sano. SEIS clases de violacion:
#
#   1. el ref no es un SHA de 40 hex          -> un tag mutable se puede reescribir (CVE-2025-30066)
#   2. no hay comentario `# <tag>`            -> nadie sabe que version es ese SHA
#   3. el tag no existe aguas arriba          -> el comentario miente
#   4. el tag no resuelve a ese SHA           -> deriva de etiqueta: el comentario envejecio
#   5. el tag es un ALIAS FLOTANTE            -> ver abajo; es la que no tenia ningun verificador
#   6. cualquier error al medir               -> exit 2, nunca un 0 silencioso
#
# LA QUINTA ES LA QUE JUSTIFICA ESTE FICHERO. Ya existia un verificador equivalente en la flota,
# en Dart, con las otras cinco. Se ejecuto sobre `actions/checkout@3d3c42e5… # v7` y devolvio
# "2 uses-lines scanned, 2 external, 0 violations": para el, `# v7` es un comentario CORRECTO,
# porque `v7` existe y apunta a ese SHA. Y lo es. El problema es otro:
#
#   Renovate clasifica la actualizacion segun lo que dice el comentario. Con `# v7` la lee como
#   cambio de DIGEST, y un digest no trae `releaseTimestamp`; con `minimumReleaseAgeBehaviour` en
#   su valor por defecto (`timestamp-required` desde la v42), una actualizacion sin timestamp no
#   puede satisfacer la reja de edad NUNCA. No da rojo: la PR se queda parada para siempre y en
#   silencio. Medido en la flota: semanas de bloqueo y tres diagnosticos fallidos.
#
# Como se detecta sin falsos positivos: `git/matching-refs/tags/<tag>` devuelve todos los refs que
# EMPIEZAN por `<tag>`, asi que `v7` trae tambien `v7.0.1`. Si alguno de esos refs mas especificos
# —el sufijo empieza por `.`— apunta al MISMO SHA, entonces `<tag>` es un alias y hay un nombre
# exacto disponible. Una accion que solo publica `vN`, sin tags de parche, no dispara nada: no hay
# ref mas especifico que ofrecerle. Una sola llamada por pin.
#
# Exit:
#   0  todos los pins sanos
#   1  al menos una violacion
#   2  no se pudo medir (sin `gh`, sin token, API caida, directorio inexistente)
set -uo pipefail

DIR="${1:-.github/workflows}"
: "${GH_API:=gh api}"
# Consulta SIN credencial, solo como ultimo recurso (ver el bloque que la usa). Inyectable para que
# la suite pueda ejercerla sin red; por defecto `curl`, porque `gh` EXIGE un token y aqui la gracia
# es justamente no llevarlo.
: "${GH_API_ANON:=}"
api_anon() { # api_anon <ruta>
  if [ -n "$GH_API_ANON" ]; then PINS_RUTA="$1" bash -c "$GH_API_ANON"; return $?; fi
  command -v curl >/dev/null 2>&1 || return 1
  # `-L`: un repo renombrado contesta 301, y `-f` NO lo considera error — sin seguirlo, lo que
  # llega es el cuerpo del redirect, que tampoco es un array. La validacion de forma ya lo caza,
  # pero es mejor resolverlo que reportarlo.
  curl -sSfL --max-time 20 -H 'Accept: application/vnd.github+json' "https://api.github.com/$1"
}
TMPERR=$(mktemp); trap 'rm -f "$TMPERR"' EXIT INT TERM          # sustituible por la suite

VIOL=0
ERRS=0
NOTAS=0
SCANNED=0
EXTERNAL=0

viol() { printf '  ✖ %s\n' "$1" >&2; VIOL=$((VIOL + 1)); }
oops() { printf '  ! %s\n' "$1" >&2; ERRS=$((ERRS + 1)); }
# Ni violacion ni no-medido: se MIDIO, pero por una via que conviene que se vea en el informe.
nota() { printf '  ~ %s\n' "$1" >&2; NOTAS=$((NOTAS + 1)); }

if [ ! -d "$DIR" ]; then
  echo "::error::no existe el directorio de workflows: $DIR" >&2
  exit 2
fi

shopt -s nullglob
FILES=("$DIR"/*.yml "$DIR"/*.yaml)
if [ "${#FILES[@]}" -eq 0 ]; then
  # Cero ficheros NO es "todos los pins sanos". Es un glob roto o un directorio equivocado, y un
  # verificador que sale 0 sin haber mirado nada es la forma mas silenciosa de dejar de gatear.
  echo "::error::$DIR no contiene ningun workflow — no hay nada que verificar, y eso es un fallo" >&2
  exit 2
fi

for f in "${FILES[@]}"; do
  while IFS= read -r line; do
    SCANNED=$((SCANNED + 1))

    # `uses:` con owner/repo. Se ignoran a proposito:
    #   ./ruta            action local del propio repo, no hay nada que pinear
    #   docker://         imagen, con su propio esquema de versionado
    raw=$(printf '%s' "$line" | sed -E 's/.*\buses:[[:space:]]*//')
    case "$raw" in ./*|docker://*) continue ;; esac
    printf '%s' "$raw" | grep -qE '^[^/[:space:]]+/[^@[:space:]]+@' || continue
    EXTERNAL=$((EXTERNAL + 1))

    owner=$(printf '%s' "$raw" | sed -E 's|^([^/]+)/.*|\1|')
    repo=$(printf  '%s' "$raw" | sed -E 's|^[^/]+/([^@]+)@.*|\1|')
    ref=$(printf   '%s' "$raw" | sed -E 's|^[^@]+@([^[:space:]]+).*|\1|')
    tag=$(printf   '%s' "$raw" | sed -nE 's|.*#[[:space:]]*([^[:space:]]+).*|\1|p')
    # Un `<repo>` puede llevar ruta (`owner/repo/.github/workflows/x.yml@sha`); la API quiere solo
    # el nombre del repositorio.
    api_repo=$(printf '%s' "$repo" | cut -d/ -f1)
    where="$(basename "$f"): $owner/$repo"

    # --- 1. el ref tiene que ser un SHA de 40 hex ----------------------------
    if ! printf '%s' "$ref" | grep -qE '^[0-9a-f]{40}$'; then
      viol "$where — el ref '$ref' no es un SHA de 40 hex: un tag es mutable y se puede reescribir"
      continue
    fi

    # --- 2. tiene que haber comentario ---------------------------------------
    if [ -z "$tag" ]; then
      viol "$where — pineado por SHA pero SIN comentario '# <version>': nadie sabe que version es"
      continue
    fi

    # --- 3/4/5. resolucion aguas arriba --------------------------------------
    # EL `rc` DE ESTA LLAMADA ES LA RESPUESTA, y estaba tirandose a la basura.
    #
    # Medido: `git/matching-refs/tags/<tag>` devuelve `[]` con **rc=0** cuando el tag no existe, y
    # **rc distinto de 0** cuando no se pudo preguntar. Son dos respuestas distintas y la API ya
    # las distingue. Aqui se juntaban en una sola condicion (`vacio O []`) y despues se DEDUCIA
    # cual era preguntando por OTRO endpoint, `repos/<owner>/<repo>`.
    #
    # Esa deduccion falla en el peor momento: si la llamada se estrangula por limite de peticiones
    # —lo normal cuando un repo tiene 68 pins externos y varias PRs a la vez— pero la consulta
    # barata del repo si contesta (o viene de cache), el resultado es una VIOLACION INVENTADA. Un
    # verificador que grita "ese tag no existe" sobre un tag que existe es peor que no tenerlo:
    # ensena a ignorarlo.
    #
    # Ahora: rc distinto de 0 -> NO MEDIDO, sin inferir nada de un endpoint que no es el que
    # fallo. rc = 0 y `[]` -> el tag no existe de verdad, y eso si es una violacion.
    # EL ERROR DE LA API SE IMPRIME, NO SE TIRA. El `2>/dev/null` que habia aqui convertia
    # cualquier fallo en "no se pudo medir" a secas: sin codigo HTTP, sin mensaje, sin nada que
    # permitiera saber si era un limite de peticiones, un permiso o un repo movido. Medido el
    # 2026-08-25: dos pins de un repo publico salieron "sin medir" en CI de forma REPETIBLE, y no
    # habia manera de averiguar por que sin tocar el script. Un diagnostico que no se puede leer
    # obliga a adivinar, y adivinar es como se llega a "el contador de GitHub esta atascado".
    #
    # Y UN REINTENTO antes de rendirse. La mayoria de estos fallos son transitorios —un 502, un
    # limite secundario por rafaga— y un verificador fail-closed que se pone rojo al primer
    # hipo se convierte en ruido. Uno solo: si el segundo tambien falla, es que pasa algo de
    # verdad y hay que verlo.
    err=""
    for intento in 1 2; do
      refs=$($GH_API "repos/$owner/$api_repo/git/matching-refs/tags/$tag" 2>"$TMPERR"); rc_refs=$?
      [ "$rc_refs" -eq 0 ] && break
      err=$(tr '\n' ' ' < "$TMPERR" | cut -c1-200)
      [ "$intento" = "1" ] && sleep 2
    done
    # ULTIMO RECURSO: PREGUNTAR SIN CREDENCIAL.
    #
    # Medido el 2026-08-25: dos pins de `aquasecurity/trivy-action`, un repo PUBLICO con el tag
    # existiendo, salian "no medido" de forma repetible desde el runner propio del estudio. El
    # mensaje, una vez que se imprimio (v0.6.2), lo dijo entero:
    #
    #   gh: Although you appear to have the correct authorization credentials, the `aquasecurity`
    #   organization has an IP allow list enabled, and your IP address is not permitted to access
    #   this resource.
    #
    # La lista blanca de IPs de una organizacion restringe el acceso AUTENTICADO a sus recursos.
    # Un repo publico se puede leer SIN credencial, y esa consulta no pasa por esa comprobacion.
    #
    # Y NO ABRE NINGUN AGUJERO, que es la unica pregunta que importa aqui: si el repo fuera
    # privado, la consulta anonima tambien falla y se sigue reportando "no medido". Esto nunca
    # convierte un fallo en un verde — solo recupera lo que ya era publico. Se anota en el informe
    # para que no parezca una verificacion normal.
    if [ "$rc_refs" -ne 0 ]; then
      refs=$(api_anon "repos/$owner/$api_repo/git/matching-refs/tags/$tag" 2>"$TMPERR"); rc_anon=$?
      # SE VALIDA LA FORMA, no que "haya venido algo". Esto es un arreglo de su primera version, y
      # el fallo es instructivo: se aceptaba cualquier respuesta no vacia, y desde el runner del
      # estudio la consulta anonima devolvio un OBJETO DE ERROR (`{"message":...}`) en vez de la
      # lista de refs. El script lo trato como resuelto, `jq` no encontro el tag dentro y lo
      # reporto como DERIVA — una violacion inventada, con el cuerpo del error incrustado en el
      # mensaje: «ese tag apunta a {"message":"». Peor que el problema que venia a resolver.
      #
      # Una respuesta valida de `matching-refs` es SIEMPRE un array. Cualquier otra cosa es un
      # fallo disfrazado de exito, y aqui se trata como lo que es: no medido.
      if [ "$rc_anon" -eq 0 ] && printf '%s' "$refs" | jq -e 'type == "array"' >/dev/null 2>&1; then
        nota "$where — '$tag' resuelto SIN credencial: la organizacion de origen bloquea por IP a este runner"
        rc_refs=0
      else
        cuerpo=$(printf '%s' "$refs" | tr '\n' ' ' | cut -c1-120)
        oops "$where — no se pudo consultar la API para '$tag' tras 2 intentos con credencial y 1 sin ella (rc=$rc_refs, anon rc=$rc_anon): ${err:-<sin mensaje>}${cuerpo:+ | respuesta anonima: $cuerpo}"
        continue
      fi
    fi
    if [ -z "$refs" ] || [ "$refs" = "[]" ]; then
      viol "$where — el comentario dice '$tag' y ese tag NO existe aguas arriba"
      continue
    fi

    exacto=$(printf '%s' "$refs" | jq -r --arg t "refs/tags/$tag" 'map(select(.ref == $t))|.[0].object.sha // ""' 2>/dev/null)
    if [ -z "$exacto" ]; then
      viol "$where — el comentario dice '$tag' y ese tag NO existe aguas arriba"
      continue
    fi

    # Un tag anotado apunta a un objeto `tag`, no al commit: hay que dar el salto o toda comparacion
    # con un SHA de commit falla por un motivo que no es el suyo.
    tipo=$(printf '%s' "$refs" | jq -r --arg t "refs/tags/$tag" 'map(select(.ref == $t))|.[0].object.type // ""' 2>/dev/null)
    if [ "$tipo" = "tag" ]; then
      deref=$($GH_API "repos/$owner/$api_repo/git/tags/$exacto" --jq '.object.sha' 2>/dev/null)
      if [ -z "$deref" ]; then oops "$where — no se pudo desreferenciar el tag anotado '$tag'"; continue; fi
      exacto="$deref"
    fi

    if [ "$exacto" != "$ref" ]; then
      viol "$where — DERIVA: el comentario dice '$tag' pero ese tag apunta a ${exacto:0:12}, no a ${ref:0:12}"
      continue
    fi

    # --- 5. alias flotante ----------------------------------------------------
    mejores=$(printf '%s' "$refs" | jq -r --arg t "$tag" '
      map(select(.ref | startswith("refs/tags/" + $t + ".")))
      | map(.ref | sub("^refs/tags/"; ""))
      | join(" ")' 2>/dev/null)
    if [ -n "$mejores" ]; then
      for m in $mejores; do
        msha=$(printf '%s' "$refs" | jq -r --arg r "refs/tags/$m" 'map(select(.ref == $r))|.[0].object.sha // ""')
        mtipo=$(printf '%s' "$refs" | jq -r --arg r "refs/tags/$m" 'map(select(.ref == $r))|.[0].object.type // ""')
        if [ "$mtipo" = "tag" ]; then
          msha=$($GH_API "repos/$owner/$api_repo/git/tags/$msha" --jq '.object.sha' 2>/dev/null)
        fi
        if [ "$msha" = "$ref" ]; then
          viol "$where — FLOTANTE: '$tag' es un alias; ese mismo SHA tiene el nombre exacto '$m'. Renovate leera la actualizacion como 'digest', sin releaseTimestamp, y la reja de edad no la dejara pasar nunca"
          break
        fi
      done
    fi
  done < <(grep -hE '^\s*-?\s*uses:' "$f" 2>/dev/null)
done

echo "check-action-pins: $SCANNED linea(s) \`uses:\`, $EXTERNAL externa(s), $VIOL violacion(es), $ERRS sin medir, $NOTAS resuelta(s) sin credencial."

# Igual que en el resto de la flota: no haber podido medir NO es estar limpio, y se decide antes
# que los hallazgos.
if [ "$ERRS" -gt 0 ]; then
  echo "::error::check-action-pins no pudo resolver $ERRS pin(s). No se afirma que los pins esten sanos." >&2
  exit 2
fi
[ "$VIOL" -eq 0 ] || exit 1
exit 0
