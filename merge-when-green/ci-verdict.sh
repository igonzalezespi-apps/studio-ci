#!/usr/bin/env bash
# ci-verdict.sh — see ci_verdict.py (its docstring is the manual: `ci-verdict.sh --help`).
set -uo pipefail
exec python3 "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/ci_verdict.py" "$@"
