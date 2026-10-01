#!/usr/bin/env bash
# pr-body.sh — a deterministic PR body (work | human | promotion). See pr_body.py: `pr-body.sh --help`.
set -uo pipefail
exec python3 "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/pr_body.py" "$@"
