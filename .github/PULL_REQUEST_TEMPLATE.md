## Para ti (negocio)

<!-- Esta es la sección que Iván lee SIEMPRE, y muchas veces la única. Sin jerga:
     nada de nombres de fichero, de funciones ni de herramientas.
     - Qué cambia para el producto o para el estudio, en 3-5 líneas.
     - Qué pasa si esto NO se mergea. -->

## Lo técnico que ratificas

<!-- Iván firma como responsable técnico aunque no revise el diff, así que aquí va
     lo que un responsable querría haber visto antes de firmar:
     - qué se ha MEDIDO (con el número, no con "se comprobó"),
     - qué se ha probado y CÓMO (suite, disparo real, mutación),
     - qué RIESGO queda vivo y por qué se acepta.
     Si la PR toca modelo de datos, API pública, gasto, credenciales/seguridad,
     el contrato o un CLAUDE.md: dilo aquí en la primera línea. -->

## Merge method

This repository is **squash-only** (enforced by repo settings): every PR lands as one commit
whose message is the **PR title**. The PR title MUST therefore be a valid Conventional Commit
(e.g. `fix(preset): correct schedule for lockfile maintenance`) - it drives the computed
changelog and version.
