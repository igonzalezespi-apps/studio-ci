---
paths:
  - 'scripts/hooks/**'
  - '.githooks/**'
  - 'bootstrap.sh'
  - '.claude/settings.json'
---

# Vendored guard and local hooks

- `scripts/hooks/bash-guard.sh` (and its two test suites) are a **byte-identical copy** of the
  core-dev guard; `scripts/hooks/.vendor.lock` records the source commit, the version and the
  checksums. Never edit them here: refresh with `guard-sync` (or `./bootstrap.sh`) and check with
  `guard-verify`. The only per-repo file is `scripts/hooks/guard.policy.json`, which states the
  protected and integration branches and whether an agent may merge.
- `.claude/settings.json` cables the guard as the `PreToolUse` Bash hook; it enforces from the
  committed copy, with or without plugins. It **fails open**: a tripwire against agent mistakes,
  not a security boundary.
- Before pushing a change here, run what `guard-selftest` runs:
  `(cd scripts/hooks && sha256sum -c .vendor.lock)` and `bash scripts/hooks/bash-guard.test.sh`.
- The `.githooks/` hooks (private-name denylist on files and commit messages) are cabled per clone
  by `./bootstrap.sh` (`git config core.hooksPath .githooks`). They are the only layer that stops
  a human commit, and a no-op where the private denylist is absent.
