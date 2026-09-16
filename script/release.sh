#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVELOPER_PATH="${DEVELOPER_DIR:-$(xcode-select -p)}"
SHA="$(git -C "$ROOT" rev-parse HEAD)"
RELEASE_ROOT="$ROOT/.artifacts/release/$SHA"
# shellcheck source=script/lib/arm64-bundle.sh
source "$ROOT/script/lib/arm64-bundle.sh"
# shellcheck source=script/lib/release-notes.sh
source "$ROOT/script/lib/release-notes.sh"
# shellcheck source=script/lib/dmg.sh
source "$ROOT/script/lib/dmg.sh"
ARCHIVE="$RELEASE_ROOT/Barline.xcarchive"
RELEASE_DERIVED_DATA="$RELEASE_ROOT/DerivedData"
SIGNING_SCRATCH=""
EXPORT_PATH=""
EXPORT_OPTIONS=""
RAW_BUILD_SETTINGS_JSON=""
UNSIGNED=false
NOTARY_PROFILE="${BARLINE_NOTARY_PROFILE:-}"
NOTARY_KEYCHAIN="${BARLINE_NOTARY_KEYCHAIN:-${HOME}/Library/Keychains/login.keychain-db}"
SPARKLE_ACCOUNT="${BARLINE_SPARKLE_ACCOUNT:-mabry-ventures-barline}"

usage() {
    printf 'usage: ./script/release.sh [--unsigned] [--notary-profile NAME] [--notary-keychain PATH] [--sparkle-account NAME]\n'
}

while (($#)); do
    case "$1" in
        --unsigned) UNSIGNED=true ;;
        --notary-profile)
            (($# >= 2)) || { usage >&2; exit 2; }
            NOTARY_PROFILE="$2"
            shift
            ;;
        --notary-keychain)
            (($# >= 2)) || { usage >&2; exit 2; }
            NOTARY_KEYCHAIN="$2"
            shift
            ;;
        --sparkle-account)
            (($# >= 2)) || { usage >&2; exit 2; }
            SPARKLE_ACCOUNT="$2"
            shift
            ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
    shift
done

validate_exact_candidate() {
    [[ "$(git -C "$ROOT" rev-parse HEAD)" == "$SHA" ]] || {
        printf 'error: release HEAD changed from captured candidate %s\n' "$SHA" >&2
        exit 1
    }
    [[ -z "$(git -C "$ROOT" status --porcelain=v1)" ]] || {
        printf 'error: release requires a clean exact candidate\n' >&2
        exit 1
    }
}

validate_exact_candidate

cleanup() {
    [[ -z "$RAW_BUILD_SETTINGS_JSON" ]] || /bin/rm -f -- "$RAW_BUILD_SETTINGS_JSON"
    [[ -z "$SIGNING_SCRATCH" ]] || /bin/rm -rf -- "$SIGNING_SCRATCH"
}
trap cleanup EXIT

if ! "$UNSIGNED"; then
    [[ -n "$NOTARY_PROFILE" ]] || { printf 'error: signed release requires --notary-profile or BARLINE_NOTARY_PROFILE\n' >&2; exit 2; }
    [[ -f "$NOTARY_KEYCHAIN" ]] || { printf 'error: notary Keychain does not exist\n' >&2; exit 2; }
    SIGNING_SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/barline-release.${SHA}.XXXXXX")"
    ARCHIVE="$SIGNING_SCRATCH/Barline.xcarchive"
    RELEASE_DERIVED_DATA="$SIGNING_SCRATCH/DerivedData"
    EXPORT_PATH="$SIGNING_SCRATCH/Export"
    EXPORT_OPTIONS="$SIGNING_SCRATCH/ExportOptions.plist"
fi

for command in xcodebuild codesign ditto hdiutil plutil ruby shasum security openssl base64 date; do
    command -v "$command" >/dev/null 2>&1 || { printf 'error: missing %s\n' "$command" >&2; exit 1; }
done
for required in LICENSE NOTICE.md THIRD_PARTY_NOTICES.md PRIVACY.md SECURITY.md docs/PROVENANCE.md docs/BUILDING.md; do
    [[ -s "$ROOT/$required" ]] || { printf 'error: required distribution file is missing or empty: %s\n' "$required" >&2; exit 1; }
done

mkdir -p "$RELEASE_ROOT"
/bin/rm -rf \
    "$ARCHIVE" \
    "$RELEASE_DERIVED_DATA" \
    "$RELEASE_ROOT/build-settings.json" \
    "$RELEASE_ROOT/build-metadata.json" \
    "$RELEASE_ROOT/distribution-boundaries.json"
RAW_BUILD_SETTINGS_JSON="$(mktemp "${TMPDIR:-/tmp}/barline-build-settings.${SHA}.XXXXXX")"
env DEVELOPER_DIR="$DEVELOPER_PATH" xcodebuild \
    -project "$ROOT/Barline.xcodeproj" -scheme Barline -configuration Release \
    -showBuildSettings -json > "$RAW_BUILD_SETTINGS_JSON"
setting() {
    /usr/bin/ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).fetch(0).fetch("buildSettings").fetch(ARGV.fetch(1), "")' \
        "$RAW_BUILD_SETTINGS_JSON" "$1"
}
require_setting() {
    local name="$1" value
    value="$(setting "$name")"
    [[ -n "$value" && "$value" != *\$\(* ]] || {
        printf 'error: required Release build setting is missing or unresolved: %s\n' "$name" >&2
        exit 1
    }
    printf '%s' "$value"
}
APP_BUNDLE_ID="$(require_setting BARLINE_APP_BUNDLE_IDENTIFIER)"
HELPER_BUNDLE_ID="$(require_setting BARLINE_MENU_SERVICE_BUNDLE_IDENTIFIER)"
INTENTS_BUNDLE_ID="$(require_setting BARLINE_INTENTS_BUNDLE_IDENTIFIER)"
APP_GROUP_ID="$(require_setting BARLINE_APP_GROUP_IDENTIFIER)"
if ! "$UNSIGNED"; then
    TEAM_ID="$(require_setting BARLINE_DEVELOPMENT_TEAM)"
    APP_PROFILE="$(require_setting BARLINE_APP_PROVISIONING_PROFILE_SPECIFIER)"
    INTENTS_PROFILE="$(require_setting BARLINE_INTENTS_PROVISIONING_PROFILE_SPECIFIER)"
    CERTIFICATE_SHA1="$(require_setting BARLINE_DEVELOPER_ID_CERTIFICATE_SHA1)"
fi
DISTRIBUTION="developer-id"
"$UNSIGNED" && DISTRIBUTION="unsigned"
/usr/bin/ruby "$ROOT/script/generate-release-build-metadata.rb" \
    "$RAW_BUILD_SETTINGS_JSON" "$RELEASE_ROOT/build-metadata.json" "$SHA" "$DISTRIBUTION"
archive_arguments=(
    -project "$ROOT/Barline.xcodeproj" -scheme Barline -configuration Release
    -destination 'generic/platform=macOS' -archivePath "$ARCHIVE"
    -derivedDataPath "$RELEASE_DERIVED_DATA"
    -clonedSourcePackagesDirPath "$RELEASE_DERIVED_DATA/SourcePackages" archive
)
if "$UNSIGNED"; then
    archive_arguments=(
        -project "$ROOT/Barline.xcodeproj" -scheme Barline -configuration Release
        -destination 'platform=macOS,arch=arm64' -archivePath "$ARCHIVE"
        -derivedDataPath "$RELEASE_DERIVED_DATA"
        -clonedSourcePackagesDirPath "$RELEASE_DERIVED_DATA/SourcePackages"
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO archive
    )
fi
env DEVELOPER_DIR="$DEVELOPER_PATH" xcodebuild "${archive_arguments[@]}"

# Barline is Apple Silicon only. Remove non-arm64 slices from prebuilt
# dependencies such as Sparkle before export signs the nested code graph.
barline_thin_bundle_to_apple_silicon "$ARCHIVE/Products/Applications/Barline.app"

if "$UNSIGNED"; then
    APP="$ARCHIVE/Products/Applications/Barline.app"
else
    # A Developer ID archive alone does not distribution-sign Sparkle's nested
    # updater executables. Xcode's export step signs the full nested graph with
    # timestamps before the release gate validates or submits the app.
    plutil -create xml1 "$EXPORT_OPTIONS"
    plutil -insert method -string developer-id "$EXPORT_OPTIONS"
    plutil -insert destination -string export "$EXPORT_OPTIONS"
    plutil -insert signingStyle -string manual "$EXPORT_OPTIONS"
    plutil -insert teamID -string "$TEAM_ID" "$EXPORT_OPTIONS"
    plutil -insert signingCertificate -string "$CERTIFICATE_SHA1" "$EXPORT_OPTIONS"
    plutil -insert provisioningProfiles -dictionary "$EXPORT_OPTIONS"
    /usr/libexec/PlistBuddy -c \
        "Add :provisioningProfiles:$APP_BUNDLE_ID string '$APP_PROFILE'" \
        "$EXPORT_OPTIONS"
    /usr/libexec/PlistBuddy -c \
        "Add :provisioningProfiles:$INTENTS_BUNDLE_ID string '$INTENTS_PROFILE'" \
        "$EXPORT_OPTIONS"
    env DEVELOPER_DIR="$DEVELOPER_PATH" xcodebuild \
        -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT_PATH" \
        -exportOptionsPlist "$EXPORT_OPTIONS"
    APP="$EXPORT_PATH/Barline.app"
fi
HELPER="$APP/Contents/XPCServices/BarlineMenuService.xpc"
INTENTS="$APP/Contents/Extensions/BarlineIntents.appex"
ruby "$ROOT/script/validate-app-intents-topology.rb" --app "$APP"
for product in "$APP" "$HELPER" "$INTENTS"; do
    [[ -e "$product" ]] || { printf 'error: archive is missing embedded product: %s\n' "$product" >&2; exit 1; }
done
[[ "$(plutil -extract CFBundleIdentifier raw -o - "$APP/Contents/Info.plist")" == "$APP_BUNDLE_ID" ]]
[[ "$(plutil -extract CFBundleIdentifier raw -o - "$HELPER/Contents/Info.plist")" == "$HELPER_BUNDLE_ID" ]]
[[ "$(plutil -extract CFBundleIdentifier raw -o - "$INTENTS/Contents/Info.plist")" == "$INTENTS_BUNDLE_ID" ]]
barline_require_apple_silicon_bundle "$APP" || { printf 'error: release application contains non-Apple Silicon code\n' >&2; exit 1; }
/usr/bin/plutil -lint "$APP/Contents/Info.plist" "$HELPER/Contents/Info.plist" "$INTENTS/Contents/Info.plist"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
for product in "$HELPER" "$INTENTS"; do
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$product/Contents/Info.plist")" == "$VERSION" ]]
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$product/Contents/Info.plist")" == "$BUILD" ]]
done
validate_exact_candidate

if "$UNSIGNED"; then
    END_SHA="$(git -C "$ROOT" rev-parse HEAD)"
    SHA_VALUE="$SHA" END_SHA_VALUE="$END_SHA" ARCHIVE_VALUE="$ARCHIVE" VERSION_VALUE="$VERSION" /usr/bin/ruby -rjson -e '
      document = {
        start_commit_sha: ENV.fetch("SHA_VALUE"), end_commit_sha: ENV.fetch("END_SHA_VALUE"),
        clean_at_end: true, exact_candidate_revalidated_after_archive: true,
        version: ENV.fetch("VERSION_VALUE"),
        unsigned_archive: ENV.fetch("ARCHIVE_VALUE"), archive_topology_validated: true,
        externally_blocked: [
          "Developer ID signing and App Group provisioning profiles",
          "Apple notarization and stapling",
          "signed clean-install and update-from-previous validation"
        ]
      }
      File.write(ARGV.fetch(0), JSON.pretty_generate(document) + "\n")
    ' "$RELEASE_ROOT/distribution-boundaries.json"
    printf 'PASS: unsigned exact-candidate archive topology validated\n'
    printf 'NOT DISTRIBUTABLE: use the credentialed release path for signing, notarization, Sparkle, and packaging\n'
    exit 0
fi

SPARKLE_FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
SPARKLE_VERSION="$SPARKLE_FRAMEWORK/Versions/Current"
SIGNED_CODE=(
    "$APP"
    "$HELPER"
    "$INTENTS"
    "$SPARKLE_FRAMEWORK"
    "$SPARKLE_VERSION/Updater.app"
    "$SPARKLE_VERSION/XPCServices/Downloader.xpc"
    "$SPARKLE_VERSION/XPCServices/Installer.xpc"
    "$SPARKLE_VERSION/Autoupdate"
)
for product in "${SIGNED_CODE[@]}"; do
    [[ -e "$product" ]] || { printf 'error: signed archive is missing nested code: %s\n' "$product" >&2; exit 1; }
    codesign --verify --strict --verbose=2 "$product"
    authority="$(codesign -dv --verbose=4 "$product" 2>&1)"
    grep -Fxq "TeamIdentifier=$TEAM_ID" <<<"$authority" || {
        printf 'error: %s is not signed by the configured Developer ID team\n' "$product" >&2
        exit 1
    }
    grep -Eq '^CodeDirectory .*flags=.*\(.*runtime.*\)' <<<"$authority" || {
        printf 'error: %s is missing Hardened Runtime\n' "$product" >&2
        exit 1
    }
done
codesign --verify --deep --strict --verbose=2 "$APP"

APP_ENTITLEMENTS="$RELEASE_ROOT/app-entitlements.plist"
INTENTS_ENTITLEMENTS="$RELEASE_ROOT/intents-entitlements.plist"
codesign -d --entitlements - --xml "$APP" > "$APP_ENTITLEMENTS"
codesign -d --entitlements - --xml "$INTENTS" > "$INTENTS_ENTITLEMENTS"
plist_array_is_exact_singleton() {
    local plist="$1" key="$2" expected="$3"
    plutil -extract "$key" json -o - "$plist" 2>/dev/null \
        | ruby -rjson -e 'value = JSON.parse(STDIN.read); exit(value == [ARGV.fetch(0)] ? 0 : 1)' "$expected"
}
plist_array_contains_exact_value() {
    local plist="$1" key="$2" expected="$3"
    plutil -extract "$key" json -o - "$plist" 2>/dev/null \
        | ruby -rjson -e 'value = JSON.parse(STDIN.read); exit(value.is_a?(Array) && value.include?(ARGV.fetch(0)) ? 0 : 1)' "$expected"
}
for entitlements in "$APP_ENTITLEMENTS" "$INTENTS_ENTITLEMENTS"; do
    plist_array_is_exact_singleton \
        "$entitlements" 'com\.apple\.security\.application-groups' "$APP_GROUP_ID" || {
        printf 'error: release entitlement App Group does not exactly match configuration: %s\n' "$entitlements" >&2
        exit 1
    }
    if plutil -extract 'com\.apple\.security\.get-task-allow' raw -o - "$entitlements" 2>/dev/null | grep -q true; then
        printf 'error: release entitlement contains get-task-allow: %s\n' "$entitlements" >&2
        exit 1
    fi
done
if ! plutil -extract 'com\.apple\.security\.files\.user-selected\.read-write' raw -o - "$APP_ENTITLEMENTS" 2>/dev/null | grep -q true ||
   plutil -extract 'com\.apple\.security\.files\.user-selected\.read-only' raw -o - "$APP_ENTITLEMENTS" 2>/dev/null | grep -q true; then
    printf 'error: release app must have only the user-selected read-write entitlement for the macOS 27 position table\n' >&2
    exit 1
fi
SIGNING_CERT_PREFIX="$SIGNING_SCRATCH/barline-signing-cert"
codesign -d "--extract-certificates=$SIGNING_CERT_PREFIX" "$APP"
SIGNING_CERT_FINGERPRINT="$(openssl x509 -inform DER -in "${SIGNING_CERT_PREFIX}0" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':')"
[[ "$SIGNING_CERT_FINGERPRINT" == "$CERTIFICATE_SHA1" ]] || {
    printf 'error: archive leaf certificate does not match the configured certificate\n' >&2
    exit 1
}

validate_embedded_profile() {
    local product="$1" expected_application_identifier="$2" label="$3"
    local profile="$product/Contents/embedded.provisionprofile"
    local decoded="$SIGNING_SCRATCH/${label}-profile.plist"
    local expiration expiration_epoch now_epoch profile_fingerprint

    [[ -s "$profile" ]] || { printf 'error: %s release profile is not embedded\n' "$label" >&2; return 1; }
    security cms -D -i "$profile" > "$decoded"
    [[ "$(plutil -extract TeamIdentifier.0 raw -o - "$decoded")" == "$TEAM_ID" ]] || {
        printf 'error: %s profile has the wrong team\n' "$label" >&2; return 1;
    }
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$decoded")" == "$expected_application_identifier" ]] || {
        printf 'error: %s profile has the wrong application identifier\n' "$label" >&2; return 1;
    }
    plist_array_contains_exact_value \
        "$decoded" 'Entitlements.com\.apple\.security\.application-groups' "$APP_GROUP_ID" || {
        printf 'error: %s profile is missing the Barline App Group\n' "$label" >&2; return 1;
    }
    [[ "$(plutil -extract ProvisionsAllDevices raw -o - "$decoded")" == true ]] || {
        printf 'error: %s profile is not a Developer ID distribution profile\n' "$label" >&2; return 1;
    }
    expiration="$(plutil -extract ExpirationDate raw -o - "$decoded")"
    expiration_epoch="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$expiration" '+%s')"
    now_epoch="$(date -u '+%s')"
    ((expiration_epoch > now_epoch)) || { printf 'error: %s profile is expired\n' "$label" >&2; return 1; }
    profile_fingerprint="$(plutil -extract DeveloperCertificates.0 raw -o - "$decoded" | base64 -D | openssl x509 -inform DER -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':')"
    [[ "$profile_fingerprint" == "$SIGNING_CERT_FINGERPRINT" ]] || {
        printf 'error: %s profile does not contain the archive signing certificate\n' "$label" >&2; return 1;
    }
}

validate_embedded_profile "$APP" "$TEAM_ID.$APP_BUNDLE_ID" app
validate_embedded_profile "$INTENTS" "$TEAM_ID.$INTENTS_BUNDLE_ID" intents

DIST="$RELEASE_ROOT/dist"
/bin/rm -rf "$DIST"
mkdir -p "$DIST"
ZIP="$DIST/Barline-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

env DEVELOPER_DIR="$DEVELOPER_PATH" xcrun notarytool submit "$ZIP" \
    --keychain-profile "$NOTARY_PROFILE" --keychain "$NOTARY_KEYCHAIN" \
    --wait --output-format json > "$RELEASE_ROOT/notarization.json"
grep -Eq '"status"[[:space:]]*:[[:space:]]*"Accepted"' "$RELEASE_ROOT/notarization.json" || { printf 'error: notarization was not accepted\n' >&2; exit 1; }
env DEVELOPER_DIR="$DEVELOPER_PATH" xcrun stapler staple "$APP"
env DEVELOPER_DIR="$DEVELOPER_PATH" xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=4 "$APP"
/bin/rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

SPARKLE_BIN="$RELEASE_DERIVED_DATA/SourcePackages/artifacts/sparkle/Sparkle/bin"
[[ -x "$SPARKLE_BIN/sign_update" && -x "$SPARKLE_BIN/generate_appcast" ]] || {
    printf 'error: resolve packages/build once so Sparkle release tools are available\n' >&2
    exit 1
}
"$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" "$ZIP" > "$ZIP.sparkle-signature.txt"

# Sparkle embeds these notes in its update dialog. Publish only the list items
# from this exact version and build's CHANGELOG section.
barline_extract_release_notes "$ROOT/CHANGELOG.md" "$VERSION" "$BUILD" "$DIST/Barline-$VERSION.md"
"$SPARKLE_BIN/generate_appcast" --account "$SPARKLE_ACCOUNT" \
    --download-url-prefix "https://github.com/Mabry-Ventures/mv-barline/releases/download/v$VERSION/" \
    --link 'https://github.com/Mabry-Ventures/mv-barline' --embed-release-notes -o "$DIST/appcast.xml" "$DIST"

# The disk image is the first-install download; the zip stays the Sparkle
# update payload. generate_appcast scans every archive in the folder, so the
# image is built only after the appcast exists, and the enclosure is checked so
# a later reordering cannot silently hand updates a disk image. Only enclosure
# URLs are inspected: embedded release notes may legitimately mention the .dmg.
EXPECTED_ENCLOSURE="https://github.com/Mabry-Ventures/mv-barline/releases/download/v$VERSION/Barline-$VERSION.zip"
barline_require_zip_enclosures "$DIST/appcast.xml" "$EXPECTED_ENCLOSURE" || exit 1
DMG="$DIST/Barline-$VERSION.dmg"
barline_build_dmg "$APP" "$DMG" Barline || exit 1
barline_require_dmg_layout "$DMG" Barline.app || exit 1
codesign --sign "$SIGNING_CERT_FINGERPRINT" --timestamp "$DMG"
codesign --verify --strict --verbose=2 "$DMG"
env DEVELOPER_DIR="$DEVELOPER_PATH" xcrun notarytool submit "$DMG" \
    --keychain-profile "$NOTARY_PROFILE" --keychain "$NOTARY_KEYCHAIN" \
    --wait --output-format json > "$RELEASE_ROOT/dmg-notarization.json"
grep -Eq '"status"[[:space:]]*:[[:space:]]*"Accepted"' "$RELEASE_ROOT/dmg-notarization.json" || { printf 'error: disk image notarization was not accepted\n' >&2; exit 1; }
env DEVELOPER_DIR="$DEVELOPER_PATH" xcrun stapler staple "$DMG"
env DEVELOPER_DIR="$DEVELOPER_PATH" xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"

validate_exact_candidate
git -C "$ROOT" archive --format=tar.gz --prefix="Barline-$VERSION/" -o "$DIST/Barline-$VERSION-source.tar.gz" "$SHA"
"$ROOT/script/generate-spdx-sbom.rb" "$ROOT" "$VERSION" "$BUILD" "$SHA" "$DIST/Barline-$VERSION.spdx.json"
validate_exact_candidate
(cd "$DIST" && shasum -a 256 "Barline-$VERSION.dmg" "Barline-$VERSION.zip" "Barline-$VERSION-source.tar.gz" "Barline-$VERSION.spdx.json" appcast.xml > SHA256SUMS)

printf 'PASS: signed, notarized, stapled, Gatekeeper-assessed release package and disk image generated at %s\n' "$DIST"
printf 'MANUAL RELEASE EVIDENCE STILL REQUIRED: clean install and update from the previous public Barline version\n'
