#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$(mktemp -d "${TMPDIR:-/tmp}/barline-fixture.XXXXXX")"
APP="$DERIVED_DATA/Build/Products/Debug/BarlineFixture.app"
CORE_SCRATCH_PATH="${BARLINE_CORE_SCRATCH_PATH:-$DERIVED_DATA/core-build}"

cleanup() {
    /usr/bin/pkill -x BarlineFixture >/dev/null 2>&1 || true
    /bin/rm -rf "$DERIVED_DATA"
}
trap cleanup EXIT

cd "$ROOT"

tests="$(swift test --package-path BarlineCore --scratch-path "$CORE_SCRATCH_PATH" list)"
fixture_count="$(printf '%s\n' "$tests" | grep -Ec '^BarlineCoreTests\.(SnapshotValidationTests|StateCoordinatorTests|ProfileTests|MenuBarCommandValidationTests)/')"
if ((fixture_count < 20)); then
    printf 'error: expected at least 20 fixture/state regression cases, found %d\n' "$fixture_count" >&2
    exit 1
fi

swift test --package-path BarlineCore --scratch-path "$CORE_SCRATCH_PATH" \
    --filter 'BarlineCoreTests\.(SnapshotValidationTests|StateCoordinatorTests|ProfileTests|MenuBarCommandValidationTests)/'

env DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}" xcodebuild \
    -project Barline.xcodeproj -scheme BarlineFixture -configuration Debug \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
[[ -x "$APP/Contents/MacOS/BarlineFixture" ]] || {
    printf 'error: fixture application product is missing\n' >&2
    exit 1
}
/usr/bin/codesign --force --deep --sign - --timestamp=none "$APP"
BARLINE_FIXTURE_MODE=gate BARLINE_FIXTURE_ITEMS=Network,Battery,Clock /usr/bin/open -g -n "$APP"
for _ in {1..20}; do
    /usr/bin/pgrep -x BarlineFixture >/dev/null && break
    /bin/sleep 0.25
done
/usr/bin/pgrep -x BarlineFixture >/dev/null || {
    printf 'error: fixture application did not remain running\n' >&2
    exit 1
}

printf 'PASS: %d fixture/state regression cases and the controllable status-item fixture app were validated\n' "$fixture_count"
