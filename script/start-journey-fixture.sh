#!/usr/bin/env bash
set -euo pipefail
if (($# != 2)); then
    printf 'usage: %s /absolute/BarlineFixture.app /absolute/ignored-artifacts-directory\n' "$0" >&2
    exit 2
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=script/lib/journey-fixture.sh
source "$SCRIPT_DIR/lib/journey-fixture.sh"

# A fixture nobody stops keeps its status items in the menu bar indefinitely.
# It quits itself after this many seconds (default four hours; 0 disables).
# Stop it earlier with script/stop-journey-fixture.sh.
LIFETIME="${BARLINE_FIXTURE_LIFETIME_SECONDS:-14400}"
if ! [[ "$LIFETIME" =~ ^[0-9]{1,5}$ ]] || ((10#$LIFETIME > 86400)); then
    printf 'error: BARLINE_FIXTURE_LIFETIME_SECONDS must be a whole number from 0 to 86400\n' >&2
    exit 2
fi
FIXTURE_APP="$1"
ARTIFACT_DIR="$2"
[[ "$FIXTURE_APP" == /* && -x "$FIXTURE_APP/Contents/MacOS/BarlineFixture" && "$ARTIFACT_DIR" == /* ]] || exit 2
if /usr/bin/pgrep -x BarlineFixture >/dev/null; then
    if [[ -n "$(barline_journey_fixture_pids)" ]]; then
        printf 'error: a journey fixture is already running; refuse to create another instance (stop it with script/stop-journey-fixture.sh)\n' >&2
    else
        printf 'error: a fixture started by a UI test, the accessibility audit or by hand is already running; refuse to create another instance (let it finish or quit it, then try again)\n' >&2
    fi
    exit 1
fi
mkdir -p "$ARTIFACT_DIR"
SESSION="$(/usr/bin/uuidgen)"
RECEIPT="$ARTIFACT_DIR/fixture-$SESSION.json"
# Background plus hidden prevents a WindowGroup launch from raising any window.
# The fixture itself switches to accessory and orders its windows out as well.
/usr/bin/open -g -j -n "$FIXTURE_APP" \
    --env BARLINE_FIXTURE_MODE=journey \
    --env "BARLINE_FIXTURE_SESSION=$SESSION" \
    --env "BARLINE_FIXTURE_RECEIPT=$RECEIPT" \
    --env "BARLINE_FIXTURE_JOURNEY_ITEMS=${BARLINE_FIXTURE_JOURNEY_ITEMS:-Native,Popover}" \
    --env "BARLINE_FIXTURE_LIFETIME_SECONDS=$((10#$LIFETIME))"
for _ in {1..40}; do
    [[ ! -s "$RECEIPT" ]] || break
    /bin/sleep 0.1
done
[[ -s "$RECEIPT" ]] || { printf 'error: fixture readiness receipt missing; no relaunch attempted\n' >&2; exit 1; }
PID="$(/usr/bin/plutil -extract processIdentifier raw -o - "$RECEIPT")"
ACTUAL_SESSION="$(/usr/bin/plutil -extract session raw -o - "$RECEIPT")"
[[ "$ACTUAL_SESSION" == "$SESSION" && "$PID" =~ ^[0-9]+$ ]] || exit 1
/bin/kill -0 "$PID" || exit 1
if ((10#$LIFETIME > 0)); then
    if barline_fixture_supports_lifetime "$FIXTURE_APP"; then
        printf 'note: the fixture quits itself in %d seconds; stop it sooner with script/stop-journey-fixture.sh\n' "$((10#$LIFETIME))" >&2
    else
        printf 'warning: this BarlineFixture build predates the lifetime setting and will not quit itself; rebuild it, or stop it with script/stop-journey-fixture.sh\n' >&2
    fi
fi
printf 'export BARLINE_FIXTURE_PID=%q\nexport BARLINE_FIXTURE_SESSION=%q\nexport BARLINE_FIXTURE_RECEIPT=%q\n' "$PID" "$SESSION" "$RECEIPT"
