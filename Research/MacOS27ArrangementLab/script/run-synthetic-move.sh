#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_RECEIPT="${1:-}"
SOURCE_TOKEN="${2:-}"
DESTINATION_RECEIPT="${3:-}"
DESTINATION_TOKEN="${4:-}"
PLACEMENT="${5:-}"
OUTPUT="${6:-}"
[[ "$SOURCE_RECEIPT" == /* && "$DESTINATION_RECEIPT" == /* && "$OUTPUT" == /* ]] || {
    /usr/bin/printf 'usage: %s source-receipt source-token destination-receipt destination-token before|after output\n' "$0" >&2
    exit 2
}
[[ -n "$SOURCE_TOKEN" && -n "$DESTINATION_TOKEN" ]] || {
    /usr/bin/printf 'error: source and destination tokens are required\n' >&2
    exit 2
}
[[ "$PLACEMENT" == before || "$PLACEMENT" == after ]] || {
    /usr/bin/printf 'error: placement must be before or after\n' >&2
    exit 2
}
[[ -s "$SOURCE_RECEIPT" && -s "$DESTINATION_RECEIPT" ]] || {
    /usr/bin/printf 'error: fixture receipt is missing\n' >&2
    exit 1
}
[[ ! -e "$OUTPUT" ]] || {
    /usr/bin/printf 'error: result output already exists\n' >&2
    exit 1
}
/bin/mkdir -p "$(dirname "$OUTPUT")"

/usr/bin/open -g -j -n "$ROOT/dist/BarlineArrangementObserver.app" \
    --args synthetic-move \
    "$SOURCE_RECEIPT" "$SOURCE_TOKEN" \
    "$DESTINATION_RECEIPT" "$DESTINATION_TOKEN" \
    "$PLACEMENT" "$OUTPUT"

for _ in {1..150}; do
    [[ -s "$OUTPUT" ]] && break
    /bin/sleep 0.1
done
[[ -s "$OUTPUT" ]] || {
    /usr/bin/printf 'error: synthetic probe did not produce a result\n' >&2
    exit 1
}
/usr/bin/plutil -extract disposition raw "$OUTPUT" >/dev/null 2>&1 || {
    /usr/bin/printf 'error: synthetic probe result is invalid\n' >&2
    /bin/cat "$OUTPUT" >&2
    exit 1
}
/usr/bin/printf '%s\n' "$OUTPUT"
