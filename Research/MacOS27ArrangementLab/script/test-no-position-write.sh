#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if /usr/bin/grep -R -E 'CFPreferencesSet|TrailingItemPreferredPositions|GoldenGatePositionTableStore|com\.apple\.MenuBar' "$ROOT/Sources"; then
    /usr/bin/printf 'error: research sources contain a forbidden position-table write dependency\n' >&2
    exit 1
fi
/usr/bin/printf 'PASS: research sources have no position-table write dependency\n'
