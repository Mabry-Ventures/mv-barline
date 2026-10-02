#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCOPE_RUN_ROOT="$(mktemp -d /private/tmp/barline-native-scope.XXXXXX)"
trap 'rm -rf "$SCOPE_RUN_ROOT"' EXIT
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
    -target arm64-apple-macos26.0 -parse-as-library \
    "$ROOT/Shared/Utilities/AXIdentityReadSupport.swift" \
    "$ROOT/Shared/Utilities/AXNativeScopeValidationSupport.swift" \
    "$ROOT/script/tests/native-ax-scope.swift" -o "$SCOPE_RUN_ROOT/native-ax-scope"
"$SCOPE_RUN_ROOT/native-ax-scope"
