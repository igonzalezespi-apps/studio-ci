#!/usr/bin/env bash
# develop-health.sh — see develop_health.py (its docstring is the manual: `develop-health.sh --help`).
set -uo pipefail
exec python3 "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/develop_health.py" "$@"
