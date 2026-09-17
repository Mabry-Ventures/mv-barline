#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${BARLINE_LAB_HOST:-cplcodex01}"
IDENTITY="${BARLINE_LAB_SSH_IDENTITY:-}"
EVIDENCE_ROOT="${1:-}"
CYCLES_PER_CLASS="${2:-20}"
[[ "$EVIDENCE_ROOT" == /* ]] || {
    /usr/bin/printf 'usage: %s /absolute/remote-evidence-directory [cycles-per-class]\n' "$0" >&2
    exit 2
}
[[ "$CYCLES_PER_CLASS" =~ ^[1-9][0-9]*$ ]] || {
    /usr/bin/printf 'error: cycles-per-class must be a positive integer\n' >&2
    exit 2
}

SSH=(/usr/bin/ssh -o BatchMode=yes)
if [[ -n "$IDENTITY" ]]; then
    SSH+=(-i "$IDENTITY")
fi
REMOTE="$HOST"
TOTAL_PASSED=0

remote_exec() {
    local command_string=""
    local quoted
    for argument in "$@"; do
        printf -v quoted '%q' "$argument"
        command_string+="$quoted "
    done
    "${SSH[@]}" "$REMOTE" "$command_string"
}

stop_fixtures() {
    # Process expansion and polling must happen on CPLCODEX01.
    # shellcheck disable=SC2016
    remote_exec /bin/bash -lc '
for process in BarlineArrangementMultiFixture BarlineArrangementSingleFixture; do
    identifiers="$(/usr/bin/pgrep -x "$process" || true)"
    [[ -z "$identifiers" ]] || /bin/kill $identifiers
done
for _ in {1..50}; do
    /usr/bin/pgrep -x BarlineArrangementMultiFixture >/dev/null ||
        /usr/bin/pgrep -x BarlineArrangementSingleFixture >/dev/null || exit 0
    /bin/sleep 0.1
done
exit 1
'
}

launch_fixtures() {
    local directory="$1"
    local variant="$2"
    # The expansion must happen on CPLCODEX01, not on the coordinating host.
    # shellcheck disable=SC2016
    remote_exec /bin/bash -lc \
        'exec "$HOME/Applications/BarlineArrangementLab/script/run-fixtures.sh" "$@"' \
        barline-pilot "$directory" "$variant"
}

recreate_beta() {
    local receipt="$1"
    remote_exec /usr/bin/swift -e '
import Foundation
DistributedNotificationCenter.default().post(
    name: Notification.Name("com.mabryventures.Barline.ArrangementMultiFixture.recreate-beta"),
    object: nil
)
Thread.sleep(forTimeInterval: 0.8)
'
    local generation=""
    for _ in {1..20}; do
        generation="$(remote_exec /usr/bin/python3 -c '
import json
import sys
receipt = json.load(open(sys.argv[1]))
print([item for item in receipt["items"] if item["token"] == "beta"][0]["generation"])
' "$receipt")"
        [[ "$generation" == 2 ]] && return 0
        /bin/sleep 0.1
    done
    /usr/bin/printf 'error: recreated beta receipt did not reach generation 2\n' >&2
    return 1
}

opposite_placement() {
    local source_receipt="$1"
    local source_token="$2"
    local destination_receipt="$3"
    local destination_token="$4"
    remote_exec /usr/bin/python3 -c '
import json
import sys

def center(path, token):
    receipt = json.load(open(path))
    matches = [item for item in receipt["items"] if item["token"] == token]
    assert len(matches) == 1 and matches[0].get("frame")
    frame = matches[0]["frame"]
    return frame["x"] + frame["width"] / 2

source = center(sys.argv[1], sys.argv[2])
destination = center(sys.argv[3], sys.argv[4])
assert source != destination
print("after" if source < destination else "before")
' "$source_receipt" "$source_token" "$destination_receipt" "$destination_token"
}

run_class() {
    local class_name="$1"
    local variant="$2"
    local source_token="$3"
    local destination_token="$4"
    local same_receipt="$5"
    local recreate="$6"

    for cycle in $(/usr/bin/seq 1 "$CYCLES_PER_CLASS"); do
        stop_fixtures
        local launch directory multi_receipt single_receipt source_receipt destination_receipt placement
        directory="$(/usr/bin/printf '%s/%s/cycle-%02d' "$EVIDENCE_ROOT" "$class_name" "$cycle")"
        launch="$(launch_fixtures "$directory" "$variant")"
        multi_receipt="$(/usr/bin/printf '%s\n' "$launch" | /usr/bin/awk -F= '/BARLINE_LAB_MULTI_RECEIPT/{print $2}')"
        single_receipt="$(/usr/bin/printf '%s\n' "$launch" | /usr/bin/awk -F= '/BARLINE_LAB_SINGLE_RECEIPT/{print $2}')"
        [[ -n "$multi_receipt" && -n "$single_receipt" ]]

        if [[ "$recreate" == yes ]]; then
            recreate_beta "$multi_receipt"
        fi
        if [[ "$same_receipt" == yes ]]; then
            source_receipt="$multi_receipt"
            destination_receipt="$multi_receipt"
        else
            source_receipt="$single_receipt"
            destination_receipt="$multi_receipt"
        fi
        placement="$(opposite_placement \
            "$source_receipt" "$source_token" \
            "$destination_receipt" "$destination_token")"

        BARLINE_LAB_HOST="$HOST" BARLINE_LAB_SSH_IDENTITY="$IDENTITY" \
            "$ROOT/script/run-p3-cycle.sh" \
            "$source_receipt" "$source_token" \
            "$destination_receipt" "$destination_token" \
            "$placement" "$directory/probe.json" "$directory/cycle.json" >/dev/null

        local disposition activation_delta
        disposition="$(remote_exec /usr/bin/plutil -extract disposition raw "$directory/cycle.json")"
        activation_delta="$(remote_exec /usr/bin/plutil -extract activationDelta raw "$directory/cycle.json")"
        [[ "$disposition" == cycleVerified && "$activation_delta" == 1 ]]
        TOTAL_PASSED=$((TOTAL_PASSED + 1))
        /usr/bin/printf '%s cycle=%02d placement=%s disposition=%s activationDelta=%s\n' \
            "$class_name" "$cycle" "$placement" "$disposition" "$activation_delta"
    done
}

run_class unique-labels unique-labels solo gamma no no
run_class duplicate-labels duplicate-labels solo gamma no no
run_class absent-labels absent-labels solo gamma no no
run_class dynamic-titles dynamic-titles solo gamma no no
run_class reversed-creation reversed-creation solo gamma no no
run_class recreated-item unique-labels beta gamma yes yes
stop_fixtures

EXPECTED_TOTAL="$((CYCLES_PER_CLASS * 6))"
[[ "$TOTAL_PASSED" -eq "$EXPECTED_TOTAL" ]]
SUMMARY="$(/usr/bin/mktemp /tmp/barline-p3-pilot-summary.XXXXXX.plist)"
trap '/bin/rm -f "$SUMMARY"' EXIT
/usr/bin/plutil -create xml1 "$SUMMARY"
/usr/bin/plutil -insert schema -integer 1 "$SUMMARY"
/usr/bin/plutil -insert disposition -string pilotVerified "$SUMMARY"
/usr/bin/plutil -insert cyclesPerClass -integer "$CYCLES_PER_CLASS" "$SUMMARY"
/usr/bin/plutil -insert admittedClassCount -integer 6 "$SUMMARY"
/usr/bin/plutil -insert totalVerifiedCycles -integer "$TOTAL_PASSED" "$SUMMARY"
/usr/bin/plutil -insert classes -array "$SUMMARY"
CLASS_INDEX=0
for class_name in unique-labels duplicate-labels absent-labels dynamic-titles reversed-creation recreated-item; do
    /usr/bin/plutil -insert "classes.$CLASS_INDEX" -string "$class_name" "$SUMMARY"
    CLASS_INDEX=$((CLASS_INDEX + 1))
done
/usr/bin/plutil -convert json "$SUMMARY"
remote_exec /usr/bin/tee "$EVIDENCE_ROOT/summary.json" < "$SUMMARY" >/dev/null
/usr/bin/printf 'PILOT_VERIFIED total=%s evidence=%s\n' "$TOTAL_PASSED" "$EVIDENCE_ROOT"
