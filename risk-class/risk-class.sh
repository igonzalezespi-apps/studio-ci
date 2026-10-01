#!/usr/bin/env bash
# risk-class.sh — classify a pull request into riesgo-0..riesgo-4. See risk_class.py for the table.
#   risk-class.sh --pr N --repo <owner>/<name> [--json]        (GitHub API, read-only)
#   risk-class.sh --facts FILE [--json]                         (offline)
#   risk-class.sh --git --base REF [--head REF] [--json]        (local checkout)
# Exit 0 measured · 2 could not measure (never merge on 2).
set -uo pipefail
exec python3 "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/risk_class.py" "$@"
