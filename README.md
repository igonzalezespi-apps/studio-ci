# studio-ci

Shared CI building blocks for the [igonzalezespi](https://github.com/igonzalezespi) studio,
consumed by **pinned git reference** the same way as
[`@studio/eslint-config`](https://github.com/igonzalezespi/eslint-config) and
[`@studio/tsconfig`](https://github.com/igonzalezespi/tsconfig) — so every project's CI shares one
source of truth instead of drifting per-repo copies.

Public because the logic isn't secret (no tokens, IPs, or anything sensitive), and a public
action resolves everywhere with zero setup.

## Actions

### `ci-gate`

One aggregate gate per workflow: the single required check. Call it from a final job that depends
on every other job, so path/label-skipped jobs never wedge the merge — `skipped` and `success`
both pass; only `failure`/`cancelled` fail it.

```yaml
jobs:
  # ... your jobs ...
  ci-gate:
    name: ci-gate
    if: always()
    needs: [lint, typecheck, test, build] # list EVERY job
    runs-on: ubuntu-latest
    steps:
      - uses: igonzalezespi/studio-ci/ci-gate@v0.1.2
        with:
          needs-json: ${{ toJSON(needs) }}
```

### `detect-changes`

Classify a PR's changed files into canonical buckets so each job runs only when relevant — a
docs-only PR runs only doc checks, and e2e/heavy jobs skip when no functional code changed.
Bi-stack defaults (JS/TS monorepos and Flutter); a repo overrides only the roots that differ via
the `filters` input.

```yaml
jobs:
  changes:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: read # REQUIRED: paths-filter lists PR files via the API on pull_request
    outputs:
      functional: ${{ steps.d.outputs.functional }}
      e2e_relevant: ${{ steps.d.outputs.e2e_relevant }}
      docs: ${{ steps.d.outputs.docs }}
    steps:
      - uses: actions/checkout@v4
      - id: d
        uses: igonzalezespi/studio-ci/detect-changes@v0.1.2

  e2e:
    needs: changes
    if: needs.changes.outputs.e2e_relevant == 'true'
    runs-on: ubuntu-latest
    steps: [...]
```

> **The `changes` job needs `pull-requests: read`.** On `pull_request`, paths-filter lists the
> changed files through the GitHub API, which requires that scope. If your workflow sets a
> top-level `permissions:` block (e.g. `contents: read`), that becomes the job's *full* grant and
> silently drops `pull-requests` — so set the permission **on the `changes` job** as shown above,
> not only at the top level. Symptom when it's missing: `Resource not accessible by integration`.

Buckets: `docs`, `ci`, `deps`, `code`, `e2e_relevant`, `db_migration`, `i18n`, `assets`, plus a
derived `functional` — true for anything but a **pure docs change**. A `ci` or `deps` change counts
as functional on purpose (fail-safe: a workflow or lockfile change can break the build, so run the
full suite). Override the defaults:

```yaml
      - uses: igonzalezespi/studio-ci/detect-changes@v0.1.2
        with:
          filters: |
            e2e_relevant:
              - 'apps/web/**'
```

### `coverage-stale-gate`

Throttle an **activity-driven** coverage workflow so it runs **at most once per window** without a
cron. Built for self-hosted desktop runners that are off at night: instead of a nightly `schedule:`
(which would queue indefinitely while the machine is off), trigger coverage on `push` to your
integration branch and let this action skip it unless the last successful run is stale. The state is
the workflow's own run history (queried via the API) — no cache, no artifact, no committed timestamp.

**Set `job` to the display name of the gated coverage job** (as in the example below). The gate and
the coverage job live in the same workflow, so a throttled run (gate ok, coverage skipped) still
completes with run-level conclusion `success` — without `job`, every push would reset the staleness
clock and real coverage would never go stale again after its first run. With `job` set, only a run
where that job itself succeeded counts as a coverage success.

```yaml
on:
  push:
    branches: [develop]
  workflow_dispatch:

permissions:
  contents: read
  actions: read                 # coverage-stale-gate reads this repo's run history

jobs:
  gate:
    runs-on: ubuntu-latest
    outputs:
      stale: ${{ steps.gate.outputs.stale }}
    steps:
      - id: gate
        uses: igonzalezespi/studio-ci/coverage-stale-gate@v0.3.2
        with:
          workflow: coverage.yml   # this file
          job: coverage            # display name of the gated job below
          branch: develop
          max-age-days: "7"

  coverage:
    needs: gate
    if: needs.gate.outputs.stale == 'true'
    runs-on: ubuntu-latest
    steps: [...]                  # run the real coverage + upload here
```

> **Needs `actions: read`** on the gate job (run-history read) and `gh` on the runner (preinstalled
> on github-hosted and on the studio runner image). Keep this workflow **out of any required check** /
> `ci-gate.needs` so a coverage run never blocks a PR. Edge cases: never-run → stale (bootstraps on
> the first push); a week with no push → no run (the last number is still valid); bursts of pushes →
> only the first past the window runs (the rest see that run's fresh success and skip). The `job`
> name never matching anything (e.g. the job was renamed) is treated as never-run → always stale:
> the gate fails open with extra coverage runs, never silently off. If your job sets an explicit
> `name:`, pass that display name — it is what the jobs API reports.

## Release control plane

Three composite actions form the homogeneous release mechanism shared by every consumer repo: derive
the next version from PR labels, promote the changelog, and write the version into whatever manifest
the stack uses. They are deliberately small and orthogonal — a repo's own release workflow wires them
together (compute → apply-version + changelog-release → commit/tag/release).

### `compute-release-version`

Derive the next semver from the highest `semver:*` label across the PRs merged into `develop` since the
last release tag. **Stack-agnostic** — it reads PR labels via the API, never a manifest. Each in-range
PR must carry **at least one** `semver:major|minor|patch|none` label — zero labels hard-fails (so a
mislabeled PR can never silently miscount a bump). A PR may carry several (e.g. a grouped bot PR
auto-labeled `semver:minor` + `semver:patch`); the highest wins (`major>minor>patch>none`), per PR and
across the range. No in-range PRs → `bump=none`, `should-release=false`, version unchanged.

| input | required | default | description |
|---|---|---|---|
| `current-version` | yes | — | current released version, `X.Y.Z` (e.g. read from the manifest on `develop`) |
| `base-ref` | no | `""` | last release tag to measure from; empty = latest tag matching `tag-prefix*`, or all merged PRs if none |
| `tag-prefix` | no | `v` | tag prefix for release tags |
| `github-token` | yes | — | token with `contents:read` + `pull-requests:read` |

Outputs: `bump` (`major|minor|patch|none`), `next-version` (`X.Y.Z`; equals current when `none`),
`next-tag` (`tag-prefix`+`next-version`), `should-release` (`true` unless `bump==none`), `pr-numbers`
(space-separated).

```yaml
jobs:
  version:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: read           # REQUIRED: lists merged PRs + tags via the API
    outputs:
      next: ${{ steps.v.outputs.next-version }}
      go: ${{ steps.v.outputs.should-release }}
    steps:
      - uses: actions/checkout@v4
      - id: v
        uses: igonzalezespi/studio-ci/compute-release-version@v0.3.0
        with:
          current-version: ${{ steps.read.outputs.version }}  # however you read the manifest
          github-token: ${{ secrets.GITHUB_TOKEN }}
```

### `changelog-release`

Promote a [Keep a Changelog](https://keepachangelog.com) `## [Unreleased]` section to a versioned
heading: it inserts a fresh empty `## [Unreleased]` on top and moves the existing entries under a new
`## [X.Y.Z] - YYYY-MM-DD`, then outputs the moved body as `notes` for `gh release --notes`. A missing
changelog is a **no-op with a warning** (empty `notes`, never fails) so a repo without one still releases.

| input | required | default | description |
|---|---|---|---|
| `version` | yes | — | the version to cut, `X.Y.Z` |
| `changelog-path` | no | `CHANGELOG.md` | path to the Keep-a-Changelog file |
| `date` | no | `""` | release date `YYYY-MM-DD`; empty = today (UTC) |
| `github-token` | no | `${{ github.token }}` | unused; accepted for a uniform call signature |

Output: `notes` — the promoted section body (multiline-safe).

```yaml
      - id: cl
        uses: igonzalezespi/studio-ci/changelog-release@v0.3.0
        with:
          version: ${{ needs.version.outputs.next }}
      # ... commit the changelog, then:
      - run: gh release create "v${{ needs.version.outputs.next }}" --notes "${{ steps.cl.outputs.notes }}"
        env: { GH_TOKEN: ${{ secrets.GITHUB_TOKEN }} }
```

### `apply-version`

Write a version into a repo's manifests, switching on the stack `kind`. One action covers every stack
in the studio; the caller `git add`s the returned `files-changed`.

| `kind` | what it writes |
|---|---|
| `npm-root` | root `package.json` `version` |
| `npm-monorepo` | **every** workspace `package.json` (and the root) in lockstep at one version (`node_modules` excluded) |
| `flutter` | `pubspec.yaml` `version:` to `X.Y.Z+N`, where `N` is a committed build-number counter it increments (absent → starts at `1`) |
| `expo` | **both** root `package.json` and `apps/movies/app.config.ts` `version:` (no build number) |

| input | required | default | description |
|---|---|---|---|
| `version` | yes | — | the version to write, `X.Y.Z` |
| `kind` | yes | — | `npm-root` \| `npm-monorepo` \| `flutter` \| `expo` |
| `build-number-file` | no | `""` | **flutter** only: path to the committed build-number counter |
| `github-token` | no | `${{ github.token }}` | unused; accepted for a uniform call signature |

Output: `files-changed` — space-separated list of files written, for `git add`.

```yaml
      - id: apply
        uses: igonzalezespi/studio-ci/apply-version@v0.3.0
        with:
          version: ${{ needs.version.outputs.next }}
          kind: flutter
          build-number-file: ios/build_number.txt   # flutter only
      - run: |
          git add ${{ steps.apply.outputs.files-changed }}
          git commit -m "chore(release): v${{ needs.version.outputs.next }}"
```

> JSON/YAML edits use a small inline `node` script (preinstalled on every runner, same as `ci-gate`) —
> **no `jq` dependency** and no `npm version`/`pnpm version` reliance, so the result is identical across
> tool majors. The monorepo case keeps all packages in lockstep by walking every workspace `package.json`.

## Versioning

Tagged `vMAJOR.MINOR.PATCH`; consumers pin a tag (`@v0.1.2`) and Renovate bumps the ref. Third-party
actions inside are SHA-pinned.

## License

MIT — see [`LICENSE`](./LICENSE).
