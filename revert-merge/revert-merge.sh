#!/usr/bin/env bash
# revert-merge.sh — see revert_merge.py (its docstring is the manual: `revert-merge.sh --help`).
set -uo pipefail
exec python3 "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/revert_merge.py" "$@"
