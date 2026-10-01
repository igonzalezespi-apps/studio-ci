#!/usr/bin/env bash
# pr-merge.sh — see pr_merge.py (its docstring is the manual: `pr-merge.sh --help`).
set -uo pipefail
exec python3 "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/pr_merge.py" "$@"
