#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=script/lib/journey-fixture.sh
source "$SCRIPT_DIR/lib/journey-fixture.sh"

fail() {
    printf 'journey-fixture: %s\n' "$*" >&2
    exit 1
}
APP=/tmp/BarlineFixture.app/Contents/MacOS/BarlineFixture

expect_match() {
    barline_is_journey_fixture_line "$1" || fail "expected a journey fixture: $1"
}
expect_no_match() {
    ! barline_is_journey_fixture_line "$1" || fail "unexpected journey fixture match: $1"
}

expect_match "$APP HOME=/Users/x BARLINE_FIXTURE_MODE=journey BARLINE_FIXTURE_SESSION=abc"
expect_match "$APP BARLINE_FIXTURE_MODE=journey"
expect_no_match "$APP BARLINE_FIXTURE_MODE=ui-test BARLINE_FIXTURE_SESSION=abc"
expect_no_match "$APP BARLINE_FIXTURE_MODE=journeyman"
expect_no_match "$APP XBARLINE_FIXTURE_MODE=journey"
expect_no_match "$APP BARLINE_FIXTURE_MODE=default"
expect_no_match "$APP --barline-fixture-accessibility-audit"
expect_no_match ""
# XCUITest's Native and Popover tests run in journey mode with the
# qualification window; they belong to the running test.
expect_no_match "$APP -ApplePersistenceIgnoreState YES BARLINE_FIXTURE_MODE=journey BARLINE_FIXTURE_SESSION=s BARLINE_FIXTURE_QUALIFICATION_WINDOW=1 BARLINE_FIXTURE_FRESH_POSITION=1"
expect_match "$APP BARLINE_FIXTURE_MODE=journey BARLINE_FIXTURE_FRESH_POSITION=1"
expect_match "$APP BARLINE_FIXTURE_MODE=journey BARLINE_FIXTURE_QUALIFICATION_WINDOW=10"

# The launcher rejects a bad lifetime before it looks at the app or launches
# anything, so these cases have no side effects.
START="$SCRIPT_DIR/start-journey-fixture.sh"
for bad in abc -1 86401 100000 1.5 ""; do
    output="$(BARLINE_FIXTURE_LIFETIME_SECONDS="$bad" bash "$START" /nonexistent.app /tmp/x 2>&1 || true)"
    if [[ -z "$bad" ]]; then
        # An empty value falls back to the default, which is valid.
        [[ "$output" != *BARLINE_FIXTURE_LIFETIME_SECONDS* ]] || fail "empty lifetime was rejected"
        continue
    fi
    [[ "$output" == *"BARLINE_FIXTURE_LIFETIME_SECONDS must be"* ]] || fail "lifetime '$bad' was not rejected"
done
for good in 0 1 14400 86400; do
    output="$(BARLINE_FIXTURE_LIFETIME_SECONDS="$good" bash "$START" /nonexistent.app /tmp/x 2>&1 || true)"
    [[ "$output" != *BARLINE_FIXTURE_LIFETIME_SECONDS* ]] || fail "lifetime '$good' was rejected"
done

# The lifetime-support probe reads the bundle's MacOS directory only.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/Old.app/Contents/MacOS" "$TMP/New.app/Contents/MacOS" "$TMP/Debug.app/Contents/MacOS"
printf 'BARLINE_FIXTURE_MODE BARLINE_FIXTURE_SESSION' >"$TMP/Old.app/Contents/MacOS/BarlineFixture"
printf 'x BARLINE_FIXTURE_LIFETIME_SECONDS x' >"$TMP/New.app/Contents/MacOS/BarlineFixture"
printf 'stub' >"$TMP/Debug.app/Contents/MacOS/BarlineFixture"
printf 'x BARLINE_FIXTURE_LIFETIME_SECONDS x' >"$TMP/Debug.app/Contents/MacOS/BarlineFixture.debug.dylib"
barline_fixture_supports_lifetime "$TMP/New.app" || fail "a build with the lifetime setting was not detected"
barline_fixture_supports_lifetime "$TMP/Debug.app" || fail "a debug build with the setting in its dylib was not detected"
! barline_fixture_supports_lifetime "$TMP/Old.app" || fail "a build without the lifetime setting was detected"
! barline_fixture_supports_lifetime "$TMP/Missing.app" || fail "a missing app was detected"

printf 'Journey fixture: 11 line-matching, 10 lifetime and 4 build-support cases passed without launching or stopping any process.\n'
