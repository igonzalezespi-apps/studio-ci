# studio-ci

Shared CI building blocks for the [igonzalezespi](https://github.com/igonzalezespi) studio,
consumed by **pinned git reference** the same way as
[`@studio/eslint-config`](https://github.com/igonzalezespi-apps/eslint-config) and
[`@studio/tsconfig`](https://github.com/igonzalezespi-apps/tsconfig) — so every project's CI shares one
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
      - uses: igonzalezespi-apps/studio-ci/ci-gate@v0.1.2
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
        uses: igonzalezespi-apps/studio-ci/detect-changes@v0.1.2

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
      - uses: igonzalezespi-apps/studio-ci/detect-changes@v0.1.2
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
        uses: igonzalezespi-apps/studio-ci/coverage-stale-gate@v0.3.2
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

### `check-pr-tldr`

A PR flagged for a **human** to read and merge must open with its own `## TL;DR`, and that section
must stand alone. The flag (`revision-humana` by default) means "a person merges this one"; that
person does not read the diff, they read that section — so a TL;DR that says «see below» or cites an
ADR it does not bring along defeats the flag. Six violation classes: no `## TL;DR`, not the first
section, under 200 characters of prose, points elsewhere, cites a source without a link or a line,
or is missing the merge command **for this PR**. A PR without the flag is not judged (exit 0, and it
says so), so the check can be wired in every repo without becoming noise.

```yaml
on:
  pull_request:
    types: [opened, edited, labeled, unlabeled, synchronize, ready_for_review]

permissions:
  contents: read
  pull-requests: read

jobs:
  tldr:
    runs-on: ubuntu-latest
    steps:
      - uses: igonzalezespi-apps/studio-ci/check-pr-tldr@vX.Y.Z
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
```

No checkout needed: it reads the PR through the API. `label` changes the flag; `pr-number`/`repo`
default to the event's.

### `context-budget`

What Claude Code loads into every session has a budget, and the repo configuration that decides
*what* is loaded must resolve to something that exists. Eight checks, each named in the output:

| check | what fails it |
|---|---|
| `size` | a file over its limit: root `CLAUDE.md` > 3,000 B, `**/output-styles/*.md` > 5,000 B, `**/contract-core.md` > 4,000 characters |
| `descriptions` | a skill, command or agent `description` (+ `when_to_use`) > 250 characters; a plugin's skill listing (skills + commands without `disable-model-invocation`) summing > 6,000 |
| `dated` | a dated paragraph or a «this line used to say» note in `CLAUDE.md`, `.claude/rules/**` or `contract-core.md` (history belongs in the commit message) |
| `marketplace` | the canonical marketplace declared without `"ref": "main"`, or its legacy path in settings/workflows; a workflow that clones it without `--branch main` |
| `output-style` | an `outputStyle` that does not resolve — Claude Code silently falls back to Default: a plugin style whose plugin is not enabled in the repo, a plugin that does not ship it, a project style that does not exist, or a name that only matches with different capitalisation; optionally, not the agreed one |
| `user-keys` | a personal key in the committed `.claude/settings.json` (`model`, `effortLevel`, `autoCompactWindow`, or a plugin from a marketplace the repo does not declare) |
| `agents` | an agent without `model` or `effort` (Haiku is exempt from `effort`), or a read-only agent with `memory` — which grants Read/Write/Edit on its own |
| `pact` | when the pact applies, not exactly one `contrato TASKS v2` line in `CLAUDE.md`, an old copy (a list entry with an alias such as `Tablero pact`) or another copy of the pact elsewhere |

**How a style name resolves** — exactly as Claude Code resolves it (verified on 2.1.286, in the
binary and with a live `claude -p` run): the lookup is **case-sensitive**, and a style is named
by its frontmatter `name:` when it has one, otherwise by its file name without `.md` — one or the
other, never both. So `"Pinya"` does not find `pinya.md`, `"explanatory"` is not the built-in
`Explanatory`, and `x.md` with `name: other` answers only to `"other"` (`"plugin:other"` for a
plugin style). The built-ins are `default`, `Proactive`, `Concise`, `Explanatory` and `Learning`;
any spelling of `default` ends in Default, which is what it asks for. When the name exists with
other capitalisation, the failure line says which one.

`size`, `descriptions` and `dated` are **budget** checks: the approval label (default
`presupuesto-contexto-aprobado`, set by a person) lets an excess through, still listed as `APROB`.
The other five are **configuration** checks, and no label makes a missing style exist. A line with
`context-budget: allow` is skipped by `dated`, `marketplace` and `pact`. Exit `0` clean (warnings
do not count), `1` violations, `2` could not measure (bad config, unknown flag) — never a silent `0`.

```yaml
on:
  pull_request:
    types: [opened, synchronize, reopened, labeled, unlabeled] # labeled: the approval label re-runs it

permissions:
  contents: read

jobs:
  context-budget:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - uses: igonzalezespi-apps/studio-ci/context-budget@vX.Y.Z
        with:
          mode: warn # report only, until the repo is on its diet; omit to enforce
```

Inputs: `path` (default `.`), `mode` (`enforce`|`warn`; empty = the config's, else `enforce`),
`config`, `approval-label`, `labels` (default: the event's PR labels). Outputs: `violations`,
`warnings`. Needs a checkout, `bash` and `python3` (stdlib only), no network, no token.

**Per-repo config** — `.github/context-budget.json` (or `.context-budget.json`), every key optional,
each one **replaces** the default (a list replaces the whole list):

```json
{
  "mode": "enforce",
  "limits": [{ "glob": "CLAUDE.md", "max_bytes": 3000 }, { "glob": "**/contract-core.md", "max_chars": 4000 }],
  "description_max_chars": 250,
  "plugin_description_sum_max_chars": 6000,
  "output_style_expected": "core-dev:owner",
  "warn_checks": ["marketplace"],
  "skip_checks": [],
  "exclude": ["**/node_modules/**", "**/fixtures/**", "**/tests/**"]
}
```

The rest (`dated_globs`, `marketplace`, `forbidden_settings_keys`, `allowed_plugin_marketplaces`,
`pact`, `plugin_description_sum_kinds`) is documented in the defaults at the top of
`context-budget/context-budget.sh`. An unknown key is an error, not a silent no-op.

**When `pact` applies** — `"pact": {"required": true}` always, `false` never. Without the key it is
inferred from what is committed, because `TASKS.md` is usually in `.gitignore` and never reaches a
CI checkout: it applies if there is a `TASKS.md` on disk, if the committed `.claude/settings.json`
enables `tablero@<marketplace>`, or if `CLAUDE.md` already carries the marker or an alias on a list
entry (so a duplicated or v1 pact is caught without `TASKS.md`). The check's line says why it
applies, or why not.

**Locally or as a pre-commit** (a repo without CI) — the script is self-contained, so one copy is
enough:

```sh
bash context-budget.sh --root . --marketplaces-dir ~/.claude/plugins/marketplaces
# .githooks/pre-commit
exec bash scripts/context-budget.sh --root "$(git rev-parse --show-toplevel)" --staged --quiet
```

`--marketplaces-dir` lets `output-style` confirm that a plugin's style really exists; without it
(as in CI, unless the repo *is* the marketplace) that one fact is reported as not verifiable
instead of guessed. By default it measures the **work tree**: in a git work tree, tracked and
non-ignored files, with their content on disk.

- `--staged` measures **what the commit will record**: the files in the git index, read from the
  index (`git cat-file`), not from disk. A file that is not in the index does not exist for it
  (unstaged, or ignored such as `.claude/settings.local.json` or `TASKS.md`), which is the view a
  CI checkout gets after the push. So an oversized `CLAUDE.md` left unstaged no longer blocks a
  commit that does not touch it, and one that is fine on disk but oversized in the index no
  longer slips through. The config file is read from the index too (an explicit `--config` that
  is not in the index is read from disk). Git hands the hook the index it is about to commit, so
  `git commit -a` and `git commit -- <path>` are measured as they will land. It needs `--root` to
  be the top of a git work tree (exit `2` otherwise). Without the flag, a pre-commit measures the
  work tree, as before.
- `--quiet` prints **findings only**: nothing at all when there are none; otherwise the `FAIL`,
  `WARN` and `APROB` lines and the summary, without the `OK` lines. Exit codes do not change, and a
  could-not-measure error (exit `2`) is always printed. Meant for a pre-commit, where a dozen `OK`
  lines on every commit are context paid by every session that commits.

Both are flags of the script, not inputs of the action: CI measures its checkout, which is
already what was committed. The default output is unchanged.

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

**The MAJOR is capped by default.** A dependency's major is not the product's major: bots label a
major dependency bump `semver:major` (correctly — it describes the *dependency*), and folding that
into the *product* version is how a repo cuts a `1.0.0` nobody asked for. So with `allow-major` at
its default `false`, a `major` in range is capped to `minor`, `major-capped` goes `true`, and the log
names the PRs that asked for it. A pre-1.0 project stays inside `0.x` no matter what the bots merge,
because `0.x` never reaches `1.0.0` by minor bumps — cutting a real major becomes a deliberate act.

| input | required | default | description |
|---|---|---|---|
| `current-version` | yes | — | current released version, `X.Y.Z` (e.g. read from the manifest on `develop`) |
| `base-ref` | no | `""` | last release tag to measure from; empty = latest tag matching `tag-prefix*`, or all merged PRs if none |
| `base-branch` | no | `develop` | branch the release PRs merged into; trunk→main repos MUST pass `main` |
| `tag-prefix` | no | `v` | tag prefix for release tags |
| `allow-major` | no | `false` | `true` lets a `semver:major` label bump the MAJOR; default caps it at `minor` |
| `github-token` | yes | — | token with `contents:read` + `pull-requests:read` |

Outputs: `bump` (`major|minor|patch|none`, **after** the cap), `bump-requested` (what the labels asked
for, before the cap), `major-capped` (`true` when the cap changed the outcome), `next-version` (`X.Y.Z`;
equals current when `none`), `next-tag` (`tag-prefix`+`next-version`), `should-release` (`true` unless
`bump==none`), `pr-numbers` (space-separated).

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
        uses: igonzalezespi-apps/studio-ci/compute-release-version@v0.3.0
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
        uses: igonzalezespi-apps/studio-ci/changelog-release@v0.3.0
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
        uses: igonzalezespi-apps/studio-ci/apply-version@v0.3.0
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

## Reusable workflows

Two whole workflows (`on: workflow_call`), called with `jobs.<id>.uses` and pinned like the actions.
Their logic is inline in the YAML (a called workflow cannot read files from this repo at its own
ref); each one has a suite next to it (`.github/workflows/*.test.sh`) that runs the real `run:` bodies.

### `security.yml`

One job, `scan` (one check, one runner start): **secrets** with gitleaks (fixed version, checksum
verified, output redacted) and **dependencies** with `pnpm audit` / `npm audit`, picked by lockfile.

| event | secrets | dependencies |
|---|---|---|
| `pull_request` | the PR's commits | only what the PR **adds** (head minus base); a PR that does not touch dependencies audits nothing |
| `push` | the pushed commits | only what the push adds |
| `schedule` / `workflow_dispatch` | the whole history | the absolute state |

The split is deliberate: a new advisory on an old dependency would otherwise turn **every** open PR
red, dependency-bot PRs included (which then stop automerging), without any of them causing it. That
red belongs to the scheduled run, which is the one that measures the state.

```yaml
on:
  pull_request:          # default types: opened, synchronize, reopened
  push:
    branches: [develop, main]
  schedule:
    - cron: "41 5 * * 1"
  workflow_dispatch:

permissions:
  contents: read

jobs:
  security:
    uses: igonzalezespi-apps/studio-ci/.github/workflows/security.yml@<sha> # vX.Y.Z
    with:
      audit-level: high            # low | moderate | high | critical
```

| input | default | description |
|---|---|---|
| `runs-on` | `ubuntu-latest` | a label, or a JSON list (`["self-hosted","linux"]`); public repos: hosted runners only |
| `secrets-scan` | `true` | run gitleaks; a repo's `.gitleaks.toml` / `.gitleaksignore` are honoured |
| `audit` | `true` | run the dependency audit |
| `audit-level` | `high` | lowest severity that fails |
| `working-directory` | `.` | folder holding the lockfile |
| `ignore-advisories` | `""` | GHSA IDs that do not count (comma/space separated), each with its reason in a comment |

**Concurrency — do not add your own around the call.** The job brings one that only cancels what
has gone *stale*: `opened`/`synchronize` of a PR share a group and a new commit cancels the old run
(the `cancelled` lands on a commit that is no longer the head). Every other event — `labeled`,
`unlabeled`, `edited`, `reopened`, `ready_for_review`, push, schedule — gets a group of its own and
neither cancels nor is cancelled. This is the fix for a measured failure: when `opened` and `labeled`
share a cancelling group, one kills the other **on the same commit**, the `cancelled` check sticks to
the PR head, the PR shows red and Renovate never automerges it (measured in another repository: 21 of 27
checks `cancelled`, 3 of 47 bot PRs automerged). The `caller-guard` step fails the run if the calling
workflow listens to label-like events **and** declares a `concurrency` at workflow level or on the
calling job. `concurrency.test.sh` evaluates both workflows' expressions event by event and kills the
"simplifications" that bring the failure back.

Exit semantics per step: `0` clean, `1` finding, `2` could not measure (registry down, gitleaks
error, bad input) — never a silent `0`. `pull_request_target` is refused. Yarn and pub are reported
as not audited (pub has no native auditor; GitHub's dependency alerts and Renovate cover it).

### `renovate-heartbeat.yml`

A Renovate that stops running says nothing: no PRs looks exactly like "everything is up to date". This
workflow pings it through the Dependency Dashboard's *"Check this box to trigger a request for
Renovate to run again"* box, which Renovate repaints **empty** on every run — so the dashboard itself
is the state, and nothing else is stored:

- box empty → Renovate answered the previous ping (or there was none): tick it again (ping sent);
- box ticked and the issue untouched for less than `max-silence-hours` → ping in flight, green;
- box ticked for longer → nobody answered: **red**.

It also fails on an open *"Action Required: Fix Renovate Configuration"* issue, on a missing dashboard,
and on any open bot PR whose head carries a `cancelled` or `timed_out` check (Renovate only automerges
green, and a cancelled check nobody re-runs parks the PR forever). *Repository problems* listed on the
dashboard are reported as warnings.

```yaml
on:
  schedule:
    - cron: "23 6 * * 1,4"   # twice a week: a dead Renovate turns red on the second run after it dies
  workflow_dispatch:

permissions:
  contents: read
  issues: write              # the ping ticks a box on the dashboard issue
  pull-requests: read
  checks: read

jobs:
  renovate-heartbeat:
    uses: igonzalezespi-apps/studio-ci/.github/workflows/renovate-heartbeat.yml@<sha> # vX.Y.Z
```

| input | default | description |
|---|---|---|
| `runs-on` | `ubuntu-latest` | as above |
| `ping` | `true` | tick the box; `false` = read-only checks (use it on a PR trigger) |
| `max-silence-hours` | `48` | how long a ping may stay unanswered |
| `stuck-prs` | `true` | look for bot PRs with a cancelled check on their head |
| `dashboard-title` | `Dependency Dashboard` | your `dependencyDashboardTitle`, if you changed it |
| `bot-login` | `renovate[bot]` | the bot's login |

The job runs with the caller's token grant (it declares no `permissions` of its own, so a read-only
caller can still use `ping: false`). Ticking the box only requests a run: Renovate's own `schedule`
still decides when PRs open.

## Versioning

Tagged `vMAJOR.MINOR.PATCH`; consumers pin a tag (`@v0.1.2`) and Renovate bumps the ref. Third-party
actions inside are SHA-pinned.

## License

MIT — see [`LICENSE`](./LICENSE).
