# Fixture `limpio`

Un repo que pasa las ocho comprobaciones de `context-budget` en modo `enforce`. Los tests lo
copian a un directorio temporal, le aplican UNA mutacion por caso y comprueban que falla por
esa regla (y que la pareja sin mutar pasa).

Los directorios con punto se guardan sin el (`dot-claude/` → `.claude/`, `dot-github/` →
`.github/`, `dot-claude-plugin/` → `.claude-plugin/`) y `CLAUDE.fixture.md` → `CLAUDE.md`:
asi este arbol no se carga como configuracion real de nadie que trabaje en este repositorio.
