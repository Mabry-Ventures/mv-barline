#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${1:-}"
VARIANT="${2:-unique-labels}"
[[ "$OUTPUT" == /* ]] || {
    /usr/bin/printf 'usage: %s /absolute/evidence-directory [variant]\n' "$0" >&2
    exit 2
}
case "$VARIANT" in
    unique-labels|duplicate-labels|absent-labels|dynamic-titles|reversed-creation) ;;
    *) /usr/bin/printf 'error: unsupported fixture variant\n' >&2; exit 2 ;;
esac
for process in BarlineArrangementMultiFixture BarlineArrangementSingleFixture; do
    if /usr/bin/pgrep -x "$process" >/dev/null; then
        /usr/bin/printf 'error: %s is already running\n' "$process" >&2
        exit 1
    fi
done
/bin/mkdir -p "$OUTPUT"
SESSION="$(/usr/bin/uuidgen)"
MULTI_RECEIPT="$OUTPUT/multi-$SESSION.json"
SINGLE_RECEIPT="$OUTPUT/single-$SESSION.json"

/usr/bin/open -g -j -n "$ROOT/dist/BarlineArrangementMultiFixture.app" \
    --env BARLINE_LAB_PUBLISHER_KIND=multi \
    --env "BARLINE_LAB_SESSION=$SESSION" \
    --env "BARLINE_LAB_FIXTURE_VARIANT=$VARIANT" \
    --env "BARLINE_LAB_FIXTURE_RECEIPT=$MULTI_RECEIPT"
/usr/bin/open -g -j -n "$ROOT/dist/BarlineArrangementSingleFixture.app" \
    --env BARLINE_LAB_PUBLISHER_KIND=single \
    --env "BARLINE_LAB_SESSION=$SESSION" \
    --env "BARLINE_LAB_FIXTURE_VARIANT=$VARIANT" \
    --env "BARLINE_LAB_FIXTURE_RECEIPT=$SINGLE_RECEIPT"

receipt_is_stable() {
    [[ -s "$1" ]] && /usr/bin/python3 -c '
import json
import sys

value = json.load(open(sys.argv[1]))
assert value["sequence"] >= 2
assert value["items"] and all(item.get("frame") for item in value["items"])
' "$1" >/dev/null 2>&1
}

for _ in {1..50}; do
    receipt_is_stable "$MULTI_RECEIPT" && receipt_is_stable "$SINGLE_RECEIPT" && break
    /bin/sleep 0.1
done
receipt_is_stable "$MULTI_RECEIPT" && receipt_is_stable "$SINGLE_RECEIPT" || {
    /usr/bin/printf 'error: stable fixture receipts were not produced\n' >&2
    exit 1
}
/usr/bin/printf 'BARLINE_LAB_SESSION=%s\n' "$SESSION"
/usr/bin/printf 'BARLINE_LAB_MULTI_RECEIPT=%s\n' "$MULTI_RECEIPT"
/usr/bin/printf 'BARLINE_LAB_SINGLE_RECEIPT=%s\n' "$SINGLE_RECEIPT"
