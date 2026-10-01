# studio-ci

Reusable **composite GitHub Actions** for the maintainer's CI, one directory per action
(`action.yml` + its shell scripts). Public (MIT). Consumers call
`igonzalezespi-apps/studio-ci/<action>@<sha>`, so each action's inputs and outputs are a public API.

## Rules

- **Public repo: never name a private project** — not in code, YAML, docs, comments, commit
  messages, PR bodies or CI. Refer to consumers neutrally ("a consuming repo"). The `.githooks/`
  hooks enforce it against a private denylist (a no-op on a fork).
- **Language:** reply to the maintainer in Spanish; code, comments and this file stay English.
- **Branch flow: `develop` → `main`.** Work PRs target `develop`, and so do dependency PRs (the
  shared Renovate preset inherits `develop`). They land by **squash** — a convention, since all
  three merge methods are enabled — so the PR title becomes the commit and MUST be a valid
  Conventional Commit: it drives the changelog and version, together with the one `semver:*`
  label every PR needs. `main` moves only through the promotion PR `develop` → `main`, which the
  maintainer merges with a merge commit and where the release tag is cut; nothing automatic, and
  no agent, ever merges into `main`.
- **Server-side, once the maintainer applies it** (public repos only; check with
  `gh api repos/<owner>/<repo>/branches/<branch>/protection`, 404 = not yet): `develop` and `main`
  need a pull request and a green `validate actions`, for admins too; no force-push, no deletion;
  only the maintainer pushes or merges into `main`. Until then CI reports and does not block. On
  top, the vendored guard in-session and the `.githooks/` hooks per clone. Run `./bootstrap.sh`
  after cloning.
- The company-wide rules come from the `studio-policy` plugin; this file keeps only what is
  specific to this repo. Path rules load on demand: `.claude/rules/actions.md` (the actions and
  their tests) and `.claude/rules/guard.md` (`scripts/hooks/`, `.githooks/`, `bootstrap.sh`).

## Reserved to the maintainer (escalate, do not decide)

Breaking an action's inputs/outputs (breaks every consumer) · making this repo private ·
anything touching spend or a published release line.
