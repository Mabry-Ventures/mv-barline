#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ROOT="$(mktemp -d /private/tmp/barline-service-recovery.XXXXXX)"
trap 'rm -rf "$RUN_ROOT"' EXIT

# Compile the actual production Session/controller against isolated transport
# and workspace doubles. Neither executable starts an app, XPC service, native
# assertion or GUI journey. The deployment target is not an OS 26 runtime test.
SWIFT_FLAGS=(-swift-version 6 -strict-concurrency=complete -warnings-as-errors
    -target arm64-apple-macos26.0 -parse-as-library)
xcrun swiftc "${SWIFT_FLAGS[@]}" -emit-library -emit-module -module-name BarlineCore \
    "$ROOT"/BarlineCore/Sources/BarlineCore/*.swift \
    -emit-module-path "$RUN_ROOT/BarlineCore.swiftmodule" -o "$RUN_ROOT/libBarlineCore.dylib"
xcrun swiftc "${SWIFT_FLAGS[@]}" -emit-library -emit-module -module-name BarlineTestXPC \
    "$ROOT/script/tests/session-recovery-mock.swift" \
    -emit-module-path "$RUN_ROOT/BarlineTestXPC.swiftmodule" -o "$RUN_ROOT/libBarlineTestXPC.dylib"
xcrun swiftc "${SWIFT_FLAGS[@]}" -D BARLINE_SESSION_TRANSPORT_TESTING \
    -I "$RUN_ROOT" -L "$RUN_ROOT" -lBarlineCore -lBarlineTestXPC \
    "$ROOT/script/tests/session-recovery.swift" \
    "$ROOT/Barline/MenuBar/MenuBarItems/BarlineMenuServiceConnection.swift" \
    "$ROOT/Shared/Services/BarlineMenuService.swift" "$ROOT/Shared/Utilities/Logging.swift" \
    -o "$RUN_ROOT/session-recovery"
DYLD_LIBRARY_PATH="$RUN_ROOT" "$RUN_ROOT/session-recovery"

if [[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 27 ]]; then
    xcrun swiftc "${SWIFT_FLAGS[@]}" -I "$RUN_ROOT" -L "$RUN_ROOT" -lBarlineCore \
        "$ROOT/script/tests/concealment-controller.swift" \
        "$ROOT/BarlineMenuService/Backends/GoldenGateConcealmentController.swift" \
        "$ROOT/Shared/Utilities/Logging.swift" -o "$RUN_ROOT/concealment-controller"
    DYLD_LIBRARY_PATH="$RUN_ROOT" "$RUN_ROOT/concealment-controller"
else
    printf '%s\n' 'SKIP: macOS 27 controller execution requires an actual macOS 27 runtime.'
fi
