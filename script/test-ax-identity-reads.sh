#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AX_READ_RUN_ROOT="$(mktemp -d /private/tmp/barline-ax-identity.XXXXXX)"
trap 'rm -rf "$AX_READ_RUN_ROOT"' EXIT
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
    -target arm64-apple-macos26.0 -parse-as-library \
    "$ROOT/Shared/Utilities/AXIdentityReadSupport.swift" \
    "$ROOT/script/tests/ax-identity-reads.swift" -o "$AX_READ_RUN_ROOT/ax-identity-reads"
"$AX_READ_RUN_ROOT/ax-identity-reads"
