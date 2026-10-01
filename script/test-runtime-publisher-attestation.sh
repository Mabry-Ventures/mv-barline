#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PUBLISHER_RUN_ROOT="$(mktemp -d /private/tmp/barline-publisher-tests.XXXXXX)"
trap 'rm -rf "$PUBLISHER_RUN_ROOT"' EXIT
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
    -target arm64-apple-macos26.0 -parse-as-library \
    "$ROOT/Shared/Utilities/RuntimePublisherAttestationSupport.swift" \
    "$ROOT/script/tests/runtime-publisher-attestation.swift" -o "$PUBLISHER_RUN_ROOT/publisher-tests"
"$PUBLISHER_RUN_ROOT/publisher-tests"
