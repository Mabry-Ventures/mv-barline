#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=script/lib/identity.sh
source "$ROOT/script/lib/identity.sh"
RUN_ROOT="${BARLINE_RUN_ROOT:-/private/tmp/barline-run-$(id -u)}"
APP="$RUN_ROOT/DerivedData/Build/Products/Debug/Barline.app"
MODULE_CACHE="${TMPDIR:-/tmp}/barline-ui-smoke-module-cache"
BINARY="${TMPDIR:-/tmp}/barline-ui-smoke"
PREFERENCE_DOMAIN="$(barline_resolve_app_bundle_identifier "$ROOT" Debug)"
PREFERENCE_KEY="UseBarlineShelf"
ORIGINAL_PREFERENCE="__missing__"

if ORIGINAL_PREFERENCE_VALUE="$(/usr/bin/defaults read "$PREFERENCE_DOMAIN" "$PREFERENCE_KEY" 2>/dev/null)"; then
    ORIGINAL_PREFERENCE="$ORIGINAL_PREFERENCE_VALUE"
fi

cleanup() {
    /usr/bin/pkill -x Barline >/dev/null 2>&1 || true
    /usr/bin/pkill -x BarlineMenuService >/dev/null 2>&1 || true
    if [[ "$ORIGINAL_PREFERENCE" == "__missing__" ]]; then
        /usr/bin/defaults delete "$PREFERENCE_DOMAIN" "$PREFERENCE_KEY" >/dev/null 2>&1 || true
    else
        if [[ "$ORIGINAL_PREFERENCE" == "1" ]]; then
            /usr/bin/defaults write "$PREFERENCE_DOMAIN" "$PREFERENCE_KEY" -bool true
        else
            /usr/bin/defaults write "$PREFERENCE_DOMAIN" "$PREFERENCE_KEY" -bool false
        fi
    fi
}
trap cleanup EXIT

/usr/bin/defaults write "$PREFERENCE_DOMAIN" "$PREFERENCE_KEY" -bool true
BARLINE_RUNTIME_SMOKE=1 "$ROOT/script/build_and_run.sh" --verify

mkdir -p "$MODULE_CACHE"
xcrun swiftc -module-cache-path "$MODULE_CACHE" \
    -framework AppKit -framework CoreGraphics \
    "$ROOT/script/test-ui-smoke.swift" -o "$BINARY"
APP_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
"$BINARY" "$APP" "$APP_BUNDLE_ID"
