#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_DIR="$ROOT/.artifacts/runtime"
OUTPUT_APP="${BARLINE_JOURNEY_HARNESS_OUTPUT:-$RUNTIME_DIR/Barline Journey Harness.app}"
SETTINGS_JSON="$(mktemp "${TMPDIR:-/tmp}/barline-journey-settings.XXXXXX")"
STAGING_DIR=""

cleanup() {
    /bin/rm -f -- "$SETTINGS_JSON"
    [[ -z "$STAGING_DIR" || ! -d "$STAGING_DIR" ]] || /bin/rm -rf -- "$STAGING_DIR"
}
trap cleanup EXIT

env DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}" xcodebuild \
    -project "$ROOT/Barline.xcodeproj" -scheme Barline -configuration Release \
    -showBuildSettings -json > "$SETTINGS_JSON"

TEAM_ID="$(SETTING_JSON="$SETTINGS_JSON" /usr/bin/ruby -rjson -e '
  records = JSON.parse(File.read(ENV.fetch("SETTING_JSON"))).select do |record|
    record["target"] == "Barline" && record.dig("buildSettings", "PRODUCT_TYPE") == "com.apple.product-type.application"
  end
  abort "expected one Barline application build-settings record" unless records.length == 1
  puts records.fetch(0).fetch("buildSettings").fetch("BARLINE_DEVELOPMENT_TEAM", "")
')"
CERTIFICATE_SHA1="$(SETTING_JSON="$SETTINGS_JSON" /usr/bin/ruby -rjson -e '
  records = JSON.parse(File.read(ENV.fetch("SETTING_JSON"))).select do |record|
    record["target"] == "Barline" && record.dig("buildSettings", "PRODUCT_TYPE") == "com.apple.product-type.application"
  end
  abort "expected one Barline application build-settings record" unless records.length == 1
  puts records.fetch(0).fetch("buildSettings").fetch("BARLINE_DEVELOPER_ID_CERTIFICATE_SHA1", "")
')"
BUNDLE_IDENTIFIER="$(SETTING_JSON="$SETTINGS_JSON" /usr/bin/ruby -rjson -e '
  records = JSON.parse(File.read(ENV.fetch("SETTING_JSON"))).select do |record|
    record["target"] == "Barline" && record.dig("buildSettings", "PRODUCT_TYPE") == "com.apple.product-type.application"
  end
  abort "expected one Barline application build-settings record" unless records.length == 1
  puts records.fetch(0).fetch("buildSettings").fetch("BARLINE_APP_BUNDLE_IDENTIFIER", "")
')"

[[ "$TEAM_ID" == "A886EMZZW6" ]] || {
    printf 'error: journey harness must use the Barline Developer ID team\n' >&2
    exit 1
}
[[ "$CERTIFICATE_SHA1" =~ ^[A-Fa-f0-9]{40}$ ]] || {
    printf 'error: Local.xcconfig must define BARLINE_DEVELOPER_ID_CERTIFICATE_SHA1\n' >&2
    exit 1
}
source "$ROOT/script/lib/identity.sh"
barline_validate_bundle_identifier "$BUNDLE_IDENTIFIER" || {
    printf 'error: BARLINE_APP_BUNDLE_IDENTIFIER is missing, unresolved, or invalid\n' >&2
    exit 1
}
HARNESS_BUNDLE_ID="${BUNDLE_IDENTIFIER}.JourneyHarness"
barline_validate_bundle_identifier "$HARNESS_BUNDLE_ID" || {
    printf 'error: derived journey harness bundle identifier is invalid\n' >&2
    exit 1
}

IDENTITY_LINE="$(/usr/bin/security find-identity -v -p codesigning | /usr/bin/grep -F "$CERTIFICATE_SHA1" | /usr/bin/head -n 1 || true)"
[[ -n "$IDENTITY_LINE" ]] || {
    printf 'error: configured Developer ID certificate is not a valid local signing identity\n' >&2
    exit 1
}
SIGNING_IDENTITY="${IDENTITY_LINE#*\"}"
SIGNING_IDENTITY="${SIGNING_IDENTITY%%\"*}"

SOURCE_SHA256="$(/usr/bin/shasum -a 256 "$ROOT/script/test-installed-journey.swift" | /usr/bin/awk '{print $1}')"
/bin/mkdir -p "$RUNTIME_DIR" "$(/usr/bin/dirname "$OUTPUT_APP")"
STAGING_DIR="$(/usr/bin/mktemp -d "$RUNTIME_DIR/.journey-harness.XXXXXX")"
STAGED_APP="$STAGING_DIR/Barline Journey Harness.app"
CONTENTS="$STAGED_APP/Contents"
EXECUTABLE="$CONTENTS/MacOS/BarlineJourneyHarness"

/bin/mkdir -p "$CONTENTS/MacOS"
env DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}" /usr/bin/xcrun swiftc \
    -framework AppKit -framework CoreGraphics \
    "$ROOT/script/test-installed-journey.swift" -o "$EXECUTABLE"

/usr/bin/plutil -create xml1 "$CONTENTS/Info.plist"
/usr/bin/plutil -insert CFBundleDisplayName -string "Barline Journey Harness" "$CONTENTS/Info.plist"
/usr/bin/plutil -insert CFBundleExecutable -string BarlineJourneyHarness "$CONTENTS/Info.plist"
/usr/bin/plutil -insert CFBundleIdentifier -string "$HARNESS_BUNDLE_ID" "$CONTENTS/Info.plist"
/usr/bin/plutil -insert CFBundleName -string "Barline Journey Harness" "$CONTENTS/Info.plist"
/usr/bin/plutil -insert CFBundlePackageType -string APPL "$CONTENTS/Info.plist"
/usr/bin/plutil -insert CFBundleShortVersionString -string 1.0.0 "$CONTENTS/Info.plist"
/usr/bin/plutil -insert CFBundleVersion -string 2 "$CONTENTS/Info.plist"
/usr/bin/plutil -insert LSUIElement -bool true "$CONTENTS/Info.plist"
/usr/bin/plutil -insert LSMinimumSystemVersion -string 26.0 "$CONTENTS/Info.plist"
/usr/bin/plutil -insert BarlineJourneySourceSHA256 -string "$SOURCE_SHA256" "$CONTENTS/Info.plist"

/usr/bin/codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$STAGED_APP"
/usr/bin/codesign --verify --deep --strict "$STAGED_APP"
AUTHORITY="$(/usr/bin/codesign -dv --verbose=4 "$STAGED_APP" 2>&1)"
grep -Fxq "TeamIdentifier=$TEAM_ID" <<<"$AUTHORITY" || {
    printf 'error: signed journey harness team does not match Barline\n' >&2
    exit 1
}

BACKUP_APP=""
if [[ -e "$OUTPUT_APP" ]]; then
    BACKUP_APP="$OUTPUT_APP.previous.$(/bin/date -u +%Y%m%dT%H%M%SZ)"
    [[ ! -e "$BACKUP_APP" ]] || { printf 'error: backup path already exists: %s\n' "$BACKUP_APP" >&2; exit 1; }
    /bin/mv "$OUTPUT_APP" "$BACKUP_APP"
fi
if ! /bin/mv "$STAGED_APP" "$OUTPUT_APP"; then
    [[ -z "$BACKUP_APP" ]] || /bin/mv "$BACKUP_APP" "$OUTPUT_APP"
    exit 1
fi

printf 'PASS: signed stable journey harness built\n'
printf 'Bundle: %s\n' "$OUTPUT_APP"
printf 'Bundle ID: %s\n' "$HARNESS_BUNDLE_ID"
printf 'Harness source SHA-256: %s\n' "$SOURCE_SHA256"
[[ -z "$BACKUP_APP" ]] || printf 'Previous bundle preserved at: %s\n' "$BACKUP_APP"
