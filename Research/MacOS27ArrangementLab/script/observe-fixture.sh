#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RECEIPT="${1:-}"
OUTPUT="${2:-}"
[[ "$RECEIPT" == /* && "$OUTPUT" == /* ]] || {
    /usr/bin/printf 'usage: %s /absolute/fixture-receipt.json /absolute/observation.json\n' "$0" >&2
    exit 2
}
[[ -s "$RECEIPT" ]] || {
    /usr/bin/printf 'error: fixture receipt is missing\n' >&2
    exit 1
}
[[ ! -e "$OUTPUT" ]] || {
    /usr/bin/printf 'error: observation output already exists\n' >&2
    exit 1
}
/bin/mkdir -p "$(dirname "$OUTPUT")"

/usr/bin/open -g -j -n "$ROOT/dist/BarlineArrangementObserver.app" \
    --args observe "$RECEIPT" "$OUTPUT"

for _ in {1..100}; do
    [[ -s "$OUTPUT" ]] && break
    /bin/sleep 0.1
done
[[ -s "$OUTPUT" ]] || {
    /usr/bin/printf 'error: observer did not produce an output file\n' >&2
    exit 1
}
[[ "$(/usr/bin/plutil -extract complete raw "$OUTPUT" 2>/dev/null || true)" == true ]] || {
    /usr/bin/printf 'error: fixture observation is incomplete\n' >&2
    /bin/cat "$OUTPUT" >&2
    exit 1
}
/usr/bin/printf '%s\n' "$OUTPUT"
