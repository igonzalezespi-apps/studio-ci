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

<!-- REQUIRED - pick exactly one.

  This repo's convention is **Squash**: every PR lands as one commit whose message is the PR
  TITLE, which therefore MUST be a valid Conventional Commit
  (e.g. `fix(setup-node): pin the action to a commit SHA`) - it drives the computed changelog and version.

  That used to be ENFORCED by the repo settings (merge commits and rebase were switched off).
  Since 2026-08-25 all three methods are enabled here, so this is policy now and nothing stops
  the wrong one. GitHub also PRESELECTS the method you used last, so check the merge box before
  clicking. -->

- [ ] Squash (the convention here - the PR TITLE becomes the commit message)
- [ ] Rebase (only for a multi-commit PR where every commit is a valid Conventional Commit)
- [ ] Merge commit (only for a stacked parent, or a promotion PR into this branch)
