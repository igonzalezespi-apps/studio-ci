# studio-ci

Shared, reusable **composite GitHub Actions** for the maintainer's CI: `apply-version`,
`changelog-release`, `ci-gate`, `compute-release-version`, `coverage-stale-gate`,
`detect-changes`. Public (MIT). Consumed by the maintainer's other repos via
`uses: igonzalezespi-apps/studio-ci/<action>@<ref>`.

## Rules

- **Public repo — never name a private project.** Not in code, YAML, shell, docs, comments,
  commit messages, or CI. Refer to consumers neutrally ("a consuming repo", "a private TS
  monorepo"). A local `pre-commit` guard (`.githooks/pre-commit`) enforces this against a
  private denylist; enable it per clone with `git config core.hooksPath .githooks` (it is a
  no-op where the denylist is absent, e.g. a fork).
- **Language / Idioma** — Reply to the maintainer in **Spanish** (he reads Spanish; this holds
  in every repo and session). Author the OpenSpec docs the maintainer reads — `proposal.md`,
  `design.md`, `tasks.md` — in **Spanish** too. Everything else stays **English**: source code,
  comments, identifiers, this contract file's own text, skills/`SKILL.md`, agent prompts, and
  OpenSpec **spec deltas** (`specs/**/spec.md`, which keep their `SHALL` / `WHEN`/`THEN` RFC2119
  keyword format).
- **Conventional Commits** — `type(scope): description` (`feat/fix/chore/docs/refactor/ci`).
- **Branch flow: trunk → main, squash-only.** PRs target `main` and every PR lands as **one
  squashed conventional commit whose message is the PR title** (enforced by repo settings).
  That commit drives the computed changelog/version, so **PR titles MUST be valid Conventional
  Commits**. Keep PR branches linear; the only sanctioned force-push is `--force-with-lease`
  on your own PR branch.
- **No secrets committed** — placeholders only.
- Each action is a self-contained `action.yml` (+ its shell scripts). Keep them dependency-free
  and stable — consumers pin them by ref, so a breaking change to an action's inputs/outputs
  is a breaking change for every consumer.

## Enforcement floor

- The agent command guard is **vendored, not a plugin hook**: `scripts/hooks/bash-guard.sh`
  (canonical source + checksums in `scripts/hooks/.vendor.lock`) is cabled as a `PreToolUse`
  Bash hook in `.claude/settings.json`, parameterised by `scripts/hooks/guard.policy.json`
  (trunk→main: no direct push to `main`, no agent-driven merge, egress limited to localhost).
  It **fail-opens**, so treat it as a tripwire against agent mistakes, not a security boundary.
- **What actually enforces here is local, and nothing is enforced server-side.** The three real
  layers are: this guard (denies the agent's command mid-session), the `.githooks/` hooks
  (`pre-commit`, `commit-msg`) once cabled per clone, and CI — which **reports, it does not
  block**: there are no required status checks, so a red run does not stop a merge. Branch
  protection and rulesets are **deliberately not enabled** on this repo (verified:
  `gh api repos/<owner>/<repo>/branches/main/protection` → `404`,
  `gh api repos/<owner>/<repo>/rulesets` → `[]`) — a standing decision, not an oversight.
  Enabling them is what would make a direct push to `main` or a merge over a red check
  *impossible* instead of merely forbidden; until then, the rules above hold by discipline.
- Run `./bootstrap.sh` after cloning: it cables the git hook, installs the declared Claude Code
  plugins (`core-dev@ivan`, `studio-policy@ivan`), refreshes/verifies the vendored guard, and
  runs its self-test. Keep the vendored guard **byte-identical** to the canonical core (refresh
  with `guard-sync`, check with `guard-verify`); edit only `guard.policy.json`.
- The **company / operating-model layer is injected by the `studio-policy` plugin**, not copied
  here — this file stays self-contained and repo-specific so it still governs on a fork that has
  no plugins installed.

## Reserved to the maintainer (escalate, do not decide)

Breaking an action's inputs/outputs (breaks every consumer) · making this repo private ·
editing this contract · anything touching spend or a published release line.
