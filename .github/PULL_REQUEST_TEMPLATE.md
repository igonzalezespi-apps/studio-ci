## TL;DR

<!-- La sección que Iván lee SIEMPRE, y casi siempre la única. Va primera y es
     AUTOCONTENIDA: sin «ver abajo», y si hace falta un ADR o una decisión vieja,
     se escribe aquí en una línea o se enlaza. Sin jerga: nada de ficheros, flags
     ni herramientas.
     - Qué cambia para los usuarios o para el estudio.
     - Qué puede salir mal y cómo se deshace.
     - Qué decisiones suyas van dentro (o «ninguna»).
     - Qué NO se ha comprobado.
     - Si la mergea él: el comando completo.
     Si esta PR NO debe mergearse todavía, se abre en DRAFT — él mergea lo que
     está listo y en verde, así que un aviso escrito aquí no la detiene. -->

## Lo técnico (decidido por el agente; queda registrado)

<!-- Telegráfico: hechos, números, comandos. Qué se MIDIÓ (con el número), qué se
     probó y CÓMO (suite, disparo real, mutación), qué riesgo queda vivo.
     Si toca modelo de datos, API pública, gasto, credenciales/seguridad, el
     contrato o un CLAUDE.md: en la primera línea. -->

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
