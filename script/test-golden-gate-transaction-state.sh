#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$(mktemp -d /private/tmp/barline-golden-gate-state.XXXXXX)"
trap 'rm -rf "$BUILD_DIR"' EXIT

xcrun clang -fobjc-arc -fmodules -Werror -Wno-nullability-completeness \
  -framework AppKit -framework Foundation \
  "$ROOT/script/tests/golden-gate-transaction-state.m" \
  -o "$BUILD_DIR/golden-gate-transaction-state"
"$BUILD_DIR/golden-gate-transaction-state"
