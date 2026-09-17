#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${BARLINE_LAB_CONFIGURATION:-debug}"
SIGN_IDENTITY="${BARLINE_LAB_SIGN_IDENTITY:--}"
DIST="$ROOT/dist"

cd "$ROOT"
/usr/bin/swift build --configuration "$CONFIGURATION"
BIN_DIR="$(/usr/bin/swift build --configuration "$CONFIGURATION" --show-bin-path)"

stage_app() {
    local app_name="$1"
    local executable_source="$2"
    local bundle_identifier="$3"
    local app="$DIST/$app_name.app"
    /bin/rm -rf "$app"
    /bin/mkdir -p "$app/Contents/MacOS"
    /bin/cp "$BIN_DIR/$executable_source" "$app/Contents/MacOS/$app_name"
    /usr/bin/plutil -create xml1 "$app/Contents/Info.plist"
    /usr/bin/plutil -insert CFBundlePackageType -string APPL "$app/Contents/Info.plist"
    /usr/bin/plutil -insert CFBundleExecutable -string "$app_name" "$app/Contents/Info.plist"
    /usr/bin/plutil -insert CFBundleIdentifier -string "$bundle_identifier" "$app/Contents/Info.plist"
    /usr/bin/plutil -insert CFBundleName -string "$app_name" "$app/Contents/Info.plist"
    /usr/bin/plutil -insert CFBundleShortVersionString -string 1.0 "$app/Contents/Info.plist"
    /usr/bin/plutil -insert CFBundleVersion -string 1 "$app/Contents/Info.plist"
    /usr/bin/plutil -insert LSMinimumSystemVersion -string 26.0 "$app/Contents/Info.plist"
    /usr/bin/plutil -insert LSUIElement -bool true "$app/Contents/Info.plist"
    /usr/bin/codesign --force --deep --options runtime --timestamp=none --sign "$SIGN_IDENTITY" "$app"
}

/bin/mkdir -p "$DIST"
stage_app BarlineArrangementMultiFixture BarlineArrangementFixture com.mabryventures.Barline.ArrangementMultiFixture
stage_app BarlineArrangementSingleFixture BarlineArrangementFixture com.mabryventures.Barline.ArrangementSingleFixture
stage_app BarlineArrangementObserver BarlineArrangementObserver com.mabryventures.Barline.ArrangementObserver

/usr/bin/printf 'Built macOS 27 arrangement lab apps in %s\n' "$DIST"
