#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=script/lib/common.sh
source "$ROOT/script/lib/common.sh"
ARTIFACT_DIR="$ROOT/.artifacts/workstreams/search-build"
mkdir -p "$ARTIFACT_DIR"

# Compile the actual actor against BarlineCore, without AppKit or app launch.
swift build --package-path "$ROOT/BarlineCore" --scratch-path "$ARTIFACT_DIR" \
    2>&1 | tee "$ARTIFACT_DIR/preferences-build.log"
BIN_PATH="$(swift build --package-path "$ROOT/BarlineCore" --scratch-path "$ARTIFACT_DIR" --show-bin-path)"
barline_resolve_core_build_products "$BIN_PATH"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
    -parse-as-library -I "$BARLINE_CORE_MODULE_PATH" \
    "$ROOT/Barline/MenuBar/Search/SearchItemPreferences.swift" \
    "$ROOT/script/tests/SearchItemPreferencesProbe.swift" \
    "${BARLINE_CORE_OBJECTS[@]}" -o "$ARTIFACT_DIR/search-preferences-probe"
TEST_DIR="$(mktemp -d "$ARTIFACT_DIR/preferences-data.XXXXXX")"
"$ARTIFACT_DIR/search-preferences-probe" "$TEST_DIR" \
    2>&1 | tee "$ARTIFACT_DIR/preferences-result.txt"
