# studio-ci

Reusable **composite GitHub Actions** and reusable workflows for the maintainer's CI, one
directory per action (`action.yml` + its scripts). Public (MIT). Consumers call
`igonzalezespi-apps/studio-ci/<action>@<sha>`, so each action's inputs and outputs are a public API.

## Rules

- **This repo is public: nothing names a private project** — not code, YAML, docs, comments,
  commits, PRs, issues or comments on them. Refer to consumers neutrally ("a consuming repo").
  The `.githooks/` hooks check files and commit messages against a private list kept on the
  maintainer's machine (fail closed there, no-op on a fork) and scan staged files with gitleaks.
  Enable them per clone: `git config core.hooksPath .githooks`.
- **Actions are a public API.** Renaming or removing an input or output, or changing what one
  means, breaks every consumer: prefer additive, opt-in inputs. Details in
  `.claude/rules/actions.md`.
- **Language:** reply to the maintainer in Spanish; code, comments and this file stay English.
- Own workflows run on GitHub-hosted runners only (a fork's PR would run on ours otherwise).

## Flow

- New worktree from `origin/develop`; PR into `develop`, landed by **squash**, so the PR title
  is the commit and must be a Conventional Commit (it drives the changelog and version).
- When its checks are green you merge it yourself:
  `gh pr merge <n> --squash --match-head-commit <sha>`. If the change is delicate, first get a
  second read with `/code-review` in a clean context.
- `main` and releases belong to the maintainer: while `develop` exists, the `develop` → `main`
  promotion is theirs (merge commit), and the release tag is cut on `main`.
- What to ask the maintainer and what you decide comes from the machine's instructions; it is
  not repeated here.

## Commands

```bash
bash <action>/<name>.test.sh                  # one suite, next to the code it tests
bash .github/workflows/<name>.test.sh         # suites for the body of a workflow's run: steps
for t in */*.test.sh .github/workflows/*.test.sh; do bash "$t" || echo "FAIL $t"; done
```

## Where things live

- Actions: `<action>/action.yml` + scripts + `*.test.sh`; documented in `README.md` (update it
  in the same PR).
- Reusable workflows (`workflow_call`): `.github/workflows/security.yml`,
  `renovate-heartbeat.yml`, `merge-when-green.yml`, `develop-health.yml`.
- CI: `ci.yml` (`validate actions`: composite check + every `*.test.sh`), `hygiene.yml`
  (gitleaks over history, CLAUDE.md ≤ 6 KB, action pins), `detect-changes-selftest.yml`,
  `reusables-selftest.yml`; release checks in `require-semver-label.yml`,
  `release-method-tripwire.yml`, `tag-has-release.yml`.
