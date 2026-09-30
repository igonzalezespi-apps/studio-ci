---
paths:
  - '*/action.yml'
  - '*/*.sh'
  - '.github/workflows/**'
  - 'README.md'
---

# The actions

- Each action is a self-contained composite `action.yml` plus its shell scripts. Keep them
  dependency-light and stable; a third-party action inside one is pinned by full commit SHA with
  its exact tag as a comment (`check-action-pins` audits exactly that).
- Consumers pin these actions by commit SHA, so renaming or removing an input or output, or
  changing what one means, breaks every consumer: that is reserved to the maintainer. Prefer
  additive, opt-in inputs with backward-compatible defaults.
- Tests sit next to the code (`<action>/*.test.sh`, and `.github/workflows/*.test.sh` for the body
  of a `run:` step). CI discovers them by glob and also checks that every `action.yml` is a
  composite action. Run them all before pushing:
  `for t in */*.test.sh .github/workflows/*.test.sh; do bash "$t" || echo "FAIL $t"; done`
- `README.md` documents each action's inputs and outputs: update it in the same PR.
- This repo is public, so its own workflows run on GitHub-hosted runners only.
