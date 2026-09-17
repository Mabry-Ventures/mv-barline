#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
OUTPUT="${1:-}"
HOST="${BARLINE_LAB_HOST:-cplcodex01}"
[[ "$OUTPUT" == /* ]] || {
    /usr/bin/printf 'usage: %s /absolute/evidence-directory\n' "$0" >&2
    exit 2
}
/bin/mkdir -p "$OUTPUT"
MANIFEST="$OUTPUT/manifest.json"
SOURCE_SHA="$(git -C "$ROOT" rev-parse HEAD)"
SOURCE_DIRTY="$(git -C "$ROOT" status --porcelain --untracked-files=no | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
LAB_SOURCE_DIGEST="$(
    /usr/bin/find "$ROOT/Research/MacOS27ArrangementLab" -type f \
        ! -path '*/.build/*' \
        ! -path '*/dist/*' \
        -print0 \
        | /usr/bin/sort -z \
        | /usr/bin/xargs -0 /usr/bin/shasum -a 256 \
        | /usr/bin/shasum -a 256 \
        | /usr/bin/awk '{print $1}'
)"
MULTI_HASH="$(/usr/bin/shasum -a 256 "$ROOT/Research/MacOS27ArrangementLab/dist/BarlineArrangementMultiFixture.app/Contents/MacOS/BarlineArrangementMultiFixture" | /usr/bin/awk '{print $1}')"
SINGLE_HASH="$(/usr/bin/shasum -a 256 "$ROOT/Research/MacOS27ArrangementLab/dist/BarlineArrangementSingleFixture.app/Contents/MacOS/BarlineArrangementSingleFixture" | /usr/bin/awk '{print $1}')"
OBSERVER_HASH="$(/usr/bin/shasum -a 256 "$ROOT/Research/MacOS27ArrangementLab/dist/BarlineArrangementObserver.app/Contents/MacOS/BarlineArrangementObserver" | /usr/bin/awk '{print $1}')"

REMOTE_VALUES="$(ssh -o BatchMode=yes "$HOST" '
set -e
product_version="$(/usr/bin/sw_vers -productVersion)"
build_version="$(/usr/bin/sw_vers -buildVersion)"
architecture="$(/usr/bin/uname -m)"
xcode_version="$(/usr/bin/xcodebuild -version | /usr/bin/head -1)"
auto_hide="$(/usr/bin/defaults read -g _HIHideMenuBar 2>/dev/null || /usr/bin/printf unset)"
display_count="$(/usr/sbin/system_profiler SPDisplaysDataType 2>/dev/null | /usr/bin/grep -c "Main Display: Yes" || true)"
barline_version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" /Applications/Barline.app/Contents/Info.plist)"
barline_build="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" /Applications/Barline.app/Contents/Info.plist)"
barline_hash_line="$(/usr/bin/shasum -a 256 /Applications/Barline.app/Contents/MacOS/Barline)"
barline_hash="${barline_hash_line%% *}"
competitors=""
for name in Bartender Ice Thaw Pelmet Barbee; do
    if /usr/bin/pgrep -x "$name" >/dev/null 2>&1; then
        if [[ -n "$competitors" ]]; then
            competitors="$competitors,$name"
        else
            competitors="$name"
        fi
    fi
done
[[ -n "$competitors" ]] || competitors="none"
/usr/bin/printf "%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n" "$product_version" "$build_version" "$architecture" "$xcode_version" "$auto_hide" "$display_count" "$barline_version" "$barline_build" "$barline_hash" "$competitors"
')"
IFS='|' read -r PRODUCT_VERSION BUILD_VERSION ARCHITECTURE XCODE_VERSION AUTO_HIDE DISPLAY_COUNT BARLINE_VERSION BARLINE_BUILD BARLINE_HASH COMPETITORS <<<"$REMOTE_VALUES"

/usr/bin/plutil -create xml1 "$MANIFEST"
/usr/bin/plutil -insert schema -integer 1 "$MANIFEST"
/usr/bin/plutil -insert capturedAtUTC -string "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" "$MANIFEST"
/usr/bin/plutil -insert sourceSHA -string "$SOURCE_SHA" "$MANIFEST"
/usr/bin/plutil -insert trackedSourceModificationCount -integer "$SOURCE_DIRTY" "$MANIFEST"
/usr/bin/plutil -insert harnessSourceSHA256 -string "$LAB_SOURCE_DIGEST" "$MANIFEST"
/usr/bin/plutil -insert hostAlias -string CPLCODEX01 "$MANIFEST"
/usr/bin/plutil -insert operatingSystemVersion -string "$PRODUCT_VERSION" "$MANIFEST"
/usr/bin/plutil -insert operatingSystemBuild -string "$BUILD_VERSION" "$MANIFEST"
/usr/bin/plutil -insert architecture -string "$ARCHITECTURE" "$MANIFEST"
/usr/bin/plutil -insert xcodeVersion -string "$XCODE_VERSION" "$MANIFEST"
/usr/bin/plutil -insert menuBarAutoHide -string "$AUTO_HIDE" "$MANIFEST"
/usr/bin/plutil -insert activeDisplayCount -integer "$DISPLAY_COUNT" "$MANIFEST"
/usr/bin/plutil -insert competingManagerProcesses -string "$COMPETITORS" "$MANIFEST"
/usr/bin/plutil -insert installedBarlineVersion -string "$BARLINE_VERSION" "$MANIFEST"
/usr/bin/plutil -insert installedBarlineBuild -string "$BARLINE_BUILD" "$MANIFEST"
/usr/bin/plutil -insert installedBarlineExecutableSHA256 -string "$BARLINE_HASH" "$MANIFEST"
/usr/bin/plutil -insert multiFixtureExecutableSHA256 -string "$MULTI_HASH" "$MANIFEST"
/usr/bin/plutil -insert singleFixtureExecutableSHA256 -string "$SINGLE_HASH" "$MANIFEST"
/usr/bin/plutil -insert observerExecutableSHA256 -string "$OBSERVER_HASH" "$MANIFEST"
/usr/bin/plutil -convert json -o "$MANIFEST" "$MANIFEST"
/usr/bin/printf 'Wrote %s\n' "$MANIFEST"
