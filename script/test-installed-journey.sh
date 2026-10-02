#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${BARLINE_CANDIDATE_APP:?Set the absolute path to the already-running signed candidate}"
: "${BARLINE_JOURNEY_HARNESS_APP:?Set the absolute path to the stable signed journey harness app}"
: "${BARLINE_SOURCE_SHA:?Set the candidate source SHA}"
: "${BARLINE_EXPECTED_PID:?Set the exact candidate PID}"
: "${BARLINE_FIXTURE_PID:?Set the exact journey fixture PID}"
: "${BARLINE_FIXTURE_RECEIPT:?Set the fixture receipt path}"
: "${BARLINE_FIXTURE_SESSION:?Set the per-run fixture session token}"
[[ "$BARLINE_SOURCE_SHA" =~ ^[a-f0-9]{40}$ ]] || { printf 'error: invalid source SHA\n' >&2; exit 2; }
[[ "$BARLINE_CANDIDATE_APP" == /* && -d "$BARLINE_CANDIDATE_APP" ]] || exit 2
source "$ROOT/script/lib/identity.sh"
CONFIGURED_APP_BUNDLE_ID="$(barline_resolve_app_bundle_identifier "$ROOT" Release)"
EXPECTED_HARNESS_BUNDLE_ID="${CONFIGURED_APP_BUNDLE_ID}.JourneyHarness"
barline_validate_bundle_identifier "$EXPECTED_HARNESS_BUNDLE_ID" || {
    printf 'error: invalid derived journey harness identity\n' >&2
    exit 1
}
/usr/bin/codesign --verify --deep --strict "$BARLINE_JOURNEY_HARNESS_APP"
HARNESS_AUTHORITY="$(/usr/bin/codesign -dv --verbose=4 "$BARLINE_JOURNEY_HARNESS_APP" 2>&1)"
grep -Fxq 'TeamIdentifier=A886EMZZW6' <<<"$HARNESS_AUTHORITY" || {
    printf 'error: journey harness is not signed by the Barline Developer ID team\n' >&2
    exit 1
}
HARNESS_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$BARLINE_JOURNEY_HARNESS_APP/Contents/Info.plist")"
[[ "$HARNESS_BUNDLE_ID" == "$EXPECTED_HARNESS_BUNDLE_ID" ]] || {
    printf 'error: unexpected journey harness identity\n' >&2
    exit 1
}
HARNESS_SOURCE_SHA="$(/usr/libexec/PlistBuddy -c 'Print :BarlineJourneySourceSHA256' "$BARLINE_JOURNEY_HARNESS_APP/Contents/Info.plist")"
ACTUAL_HARNESS_SOURCE_SHA="$(/usr/bin/shasum -a 256 "$ROOT/script/test-installed-journey.swift" | /usr/bin/awk '{print $1}')"
[[ "$HARNESS_SOURCE_SHA" == "$ACTUAL_HARNESS_SOURCE_SHA" ]] || {
    printf 'error: stable journey harness was not built from this source file\n' >&2
    exit 1
}
/usr/bin/codesign --verify --deep --strict "$BARLINE_CANDIDATE_APP"
/usr/sbin/spctl --assess --type execute "$BARLINE_CANDIDATE_APP"
/usr/bin/xcrun stapler validate "$BARLINE_CANDIDATE_APP"
RELEASE_DIR="${BARLINE_RELEASE_DIR:-$ROOT/.artifacts/release/$BARLINE_SOURCE_SHA}"
METADATA="$RELEASE_DIR/build-metadata.json"
[[ -f "$METADATA" ]] || { printf 'error: candidate source metadata missing\n' >&2; exit 1; }
ACTUAL_SHA="$(/usr/bin/plutil -extract commit_sha raw -o - "$METADATA")"
[[ "$ACTUAL_SHA" == "$BARLINE_SOURCE_SHA" ]] || { printf 'error: candidate source mismatch\n' >&2; exit 1; }
export BARLINE_APP_BUNDLE_IDENTIFIER
BARLINE_APP_BUNDLE_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$BARLINE_CANDIDATE_APP/Contents/Info.plist")"
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$BARLINE_CANDIDATE_APP/Contents/Info.plist")"
export BARLINE_EXECUTABLE_SHA256
BARLINE_EXECUTABLE_SHA256="$(/usr/bin/shasum -a 256 "$BARLINE_CANDIDATE_APP/Contents/MacOS/$EXECUTABLE" | /usr/bin/awk '{print $1}')"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BARLINE_CANDIDATE_APP/Contents/Info.plist")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 2
RELEASE_ZIP="$RELEASE_DIR/dist/Barline-$VERSION.zip"
[[ -f "$RELEASE_ZIP" ]] || { printf 'error: source-bound release ZIP missing\n' >&2; exit 1; }
PACKAGED_SHA="$(/usr/bin/unzip -p "$RELEASE_ZIP" "Barline.app/Contents/MacOS/$EXECUTABLE" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
[[ "$PACKAGED_SHA" == "$BARLINE_EXECUTABLE_SHA256" ]] || { printf 'error: installed executable differs from source-bound release\n' >&2; exit 1; }
HARNESS_EXECUTABLE="$BARLINE_JOURNEY_HARNESS_APP/Contents/MacOS/BarlineJourneyHarness"
[[ -x "$HARNESS_EXECUTABLE" ]] || { printf 'error: stable signed journey harness executable missing\n' >&2; exit 1; }
if [[ -n "${BARLINE_EVIDENCE_OUTPUT:-}" ]]; then
    : "${BARLINE_JOURNEY_LANE:?Set the exact qualification journey lane}"
    # Source-bound evidence cannot be emitted from a modified checkout.
    source "$ROOT/script/lib/installed-candidate.sh"
    barline_verify_installed_candidate
    "$HARNESS_EXECUTABLE" | tee "$BARLINE_EVIDENCE_OUTPUT.log"
    barline_verify_installed_candidate
    ruby "$ROOT/script/write-installed-evidence.rb" --kind target-interface \
        --log "$BARLINE_EVIDENCE_OUTPUT.log" --output "$BARLINE_EVIDENCE_OUTPUT"
else
    "$HARNESS_EXECUTABLE"
fi
