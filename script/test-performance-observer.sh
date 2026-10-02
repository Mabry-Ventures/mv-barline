#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/barline-performance-observer.XXXXXX")"
trap '/bin/rm -f "$PROBE_BUILD/main.swift" "$PROBE_BUILD/observer"; /bin/rmdir "$PROBE_BUILD"' EXIT
cp "$ROOT/script/measure-barline-shelf-responsiveness.swift" "$PROBE_BUILD/main.swift"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
    -framework AppKit -framework CoreGraphics \
    "$ROOT/script/ConcurrentObservation.swift" "$ROOT/script/StatusItemFrameMatching.swift" \
    "$ROOT/script/ShelfProbeCycle.swift" "$PROBE_BUILD/main.swift" -o "$PROBE_BUILD/observer"
BARLINE_PERFORMANCE_OBSERVER_SELF_TEST=1 "$PROBE_BUILD/observer"
