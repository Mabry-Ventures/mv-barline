#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=script/lib/common.sh
source "$ROOT/script/lib/common.sh"
ARTIFACT_DIR="$ROOT/.artifacts/workstreams/hotkey-registry"
mkdir -p "$ARTIFACT_DIR"
swift build --package-path "$ROOT/BarlineCore" --scratch-path "$ARTIFACT_DIR" > "$ARTIFACT_DIR/build.log" 2>&1
BIN_PATH="$(swift build --package-path "$ROOT/BarlineCore" --scratch-path "$ARTIFACT_DIR" --show-bin-path)"
barline_resolve_core_build_products "$BIN_PATH"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
    -parse-as-library -I "$BARLINE_CORE_MODULE_PATH" \
    "$ROOT/Barline/Hotkeys/KeyCode.swift" "$ROOT/Barline/Hotkeys/Modifiers.swift" \
    "$ROOT/Barline/Hotkeys/KeyCombination.swift" "$ROOT/Barline/Hotkeys/HotkeyRegistry.swift" \
    "$ROOT/Shared/Utilities/Logging.swift" "$ROOT/script/tests/HotkeyRegistryProbe.swift" \
    "${BARLINE_CORE_OBJECTS[@]}" -o "$ARTIFACT_DIR/hotkey-registry-probe"
"$ARTIFACT_DIR/hotkey-registry-probe" 2>&1 | tee "$ARTIFACT_DIR/result.txt"
