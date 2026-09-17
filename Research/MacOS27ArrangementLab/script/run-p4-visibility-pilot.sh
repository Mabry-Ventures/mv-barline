#!/usr/bin/env bash
set -euo pipefail

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
ACTIVE_STOP=""
ACTIVE_ENDED=""

remote_exec() {
    local command_string=""
    local quoted
    for argument in "$@"; do
        printf -v quoted '%q' "$argument"
        command_string+="$quoted "
    done
    "${SSH[@]}" "$HOST" "$command_string"
}

position_digest() {
    # Expansion belongs to CPLCODEX01.
    # shellcheck disable=SC2016
    remote_exec /bin/bash -lc '
/usr/bin/defaults read "$HOME/Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar" TrailingItemPreferredPositions |
    /usr/bin/shasum -a 256 |
    /usr/bin/awk "{print \$1}"
'
}

observe_application() {
    local bundle_identifier="$1"
    local output="$2"
    # Expansion belongs to CPLCODEX01.
    # shellcheck disable=SC2016
    remote_exec /bin/bash -lc '
set -euo pipefail
bundle_identifier="$1"
output="$2"
observer="$HOME/Applications/BarlineArrangementLab/dist/BarlineArrangementObserver.app"
[[ ! -e "$output" ]]
/usr/bin/open -g -j -n "$observer" --args application-visibility "$bundle_identifier" "$output"
for _ in {1..100}; do
    [[ -s "$output" ]] && exit 0
    /bin/sleep 0.1
done
exit 1
' barline-p4 "$bundle_identifier" "$output"
}

field() {
    local path="$1"
    local key="$2"
    remote_exec /usr/bin/python3 -c '
import json
import sys
print(json.load(open(sys.argv[1]))[sys.argv[2]])
' "$path" "$key"
}

start_assertion() {
    local bundle_identifier="$1"
    local ready="$2"
    local stop="$3"
    local ended="$4"
    # Expansion belongs to CPLCODEX01.
    # shellcheck disable=SC2016
    remote_exec /bin/bash -lc '
set -euo pipefail
bundle_identifier="$1"
ready="$2"
stop="$3"
ended="$4"
probe="$HOME/Applications/BarlineArrangementLab/dist/BarlineVisibilityProbe.app"
[[ ! -e "$ready" && ! -e "$stop" && ! -e "$ended" ]]
/usr/bin/open -g -j -n "$probe" --args hold "$ready" "$stop" "$ended" "$bundle_identifier"
for _ in {1..100}; do
    [[ -s "$ready" ]] && exit 0
    /bin/sleep 0.1
done
exit 1
' barline-p4 "$bundle_identifier" "$ready" "$stop" "$ended"
}

stop_assertion() {
    local stop="$1"
    local ended="$2"
    # Expansion belongs to CPLCODEX01.
    # shellcheck disable=SC2016
    remote_exec /bin/bash -lc '
set -euo pipefail
stop="$1"
ended="$2"
: > "$stop"
for _ in {1..100}; do
    [[ -s "$ended" ]] && exit 0
    /bin/sleep 0.1
done
exit 1
' barline-p4 "$stop" "$ended"
}

cleanup() {
    if [[ -n "$ACTIVE_STOP" && -n "$ACTIVE_ENDED" ]]; then
        stop_assertion "$ACTIVE_STOP" "$ACTIVE_ENDED" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

validate_observation() {
    local path="$1"
    local expected_total="$2"
    local expected_hittable="$3"
    remote_exec /usr/bin/python3 -c '
import json
import sys
value = json.load(open(sys.argv[1]))
assert value["schema"] == 1
assert value["menuExtraCount"] == int(sys.argv[2]), value
assert value["hittableMenuExtraCount"] == int(sys.argv[3]), value
' "$path" "$expected_total" "$expected_hittable"
}

run_class() {
    local class_name="$1"
    local target_bundle="$2"
    local control_bundle="$3"
    local target_count="$4"
    local target_hittable="$5"
    local control_count="$6"
    local control_hittable="$7"

    for cycle in $(/usr/bin/seq 1 "$CYCLES_PER_CLASS"); do
        local directory ready stop ended target_hidden control_active target_restored control_restored
        directory="$(/usr/bin/printf '%s/%s/cycle-%02d' "$EVIDENCE_ROOT" "$class_name" "$cycle")"
        remote_exec /bin/mkdir -p "$directory"
        ready="$directory/assertion-ready.json"
        stop="$directory/assertion.stop"
        ended="$directory/assertion-ended.json"
        target_hidden="$directory/target-hidden.json"
        control_active="$directory/control-while-hidden.json"
        target_restored="$directory/target-restored.json"
        control_restored="$directory/control-restored.json"

        ACTIVE_STOP="$stop"
        ACTIVE_ENDED="$ended"
        start_assertion "$target_bundle" "$ready" "$stop" "$ended"
        /bin/sleep 0.75
        observe_application "$target_bundle" "$target_hidden"
        observe_application "$control_bundle" "$control_active"
        validate_observation "$target_hidden" "$target_count" 0
        validate_observation "$control_active" "$control_count" "$control_hittable"

        stop_assertion "$stop" "$ended"
        ACTIVE_STOP=""
        ACTIVE_ENDED=""
        /bin/sleep 0.75
        observe_application "$target_bundle" "$target_restored"
        observe_application "$control_bundle" "$control_restored"
        validate_observation "$target_restored" "$target_count" "$target_hittable"
        validate_observation "$control_restored" "$control_count" "$control_hittable"
    done
}

remote_exec /bin/mkdir -p "$EVIDENCE_ROOT"
if remote_exec /usr/bin/pgrep -x BarlineVisibilityProbe >/dev/null 2>&1; then
    /usr/bin/printf 'error: BarlineVisibilityProbe is already running\n' >&2
    exit 1
fi

BASELINE_DIGEST="$(position_digest)"
STATS_BASELINE="$EVIDENCE_ROOT/stats-baseline.json"
ONEPASSWORD_BASELINE="$EVIDENCE_ROOT/onepassword-baseline.json"
observe_application eu.exelban.Stats "$STATS_BASELINE"
observe_application com.1password.1password "$ONEPASSWORD_BASELINE"
STATS_COUNT="$(field "$STATS_BASELINE" menuExtraCount)"
ONEPASSWORD_COUNT="$(field "$ONEPASSWORD_BASELINE" menuExtraCount)"
STATS_HITTABLE="$(field "$STATS_BASELINE" hittableMenuExtraCount)"
ONEPASSWORD_HITTABLE="$(field "$ONEPASSWORD_BASELINE" hittableMenuExtraCount)"
[[ "$STATS_COUNT" -gt 1 && "$ONEPASSWORD_COUNT" -eq 1 ]]
[[ "$STATS_HITTABLE" -gt 1 && "$ONEPASSWORD_HITTABLE" -eq 1 ]]
validate_observation "$STATS_BASELINE" "$STATS_COUNT" "$STATS_HITTABLE"
validate_observation "$ONEPASSWORD_BASELINE" "$ONEPASSWORD_COUNT" "$ONEPASSWORD_HITTABLE"

run_class single-item com.1password.1password eu.exelban.Stats \
    "$ONEPASSWORD_COUNT" "$ONEPASSWORD_HITTABLE" "$STATS_COUNT" "$STATS_HITTABLE"
run_class application-group eu.exelban.Stats com.1password.1password \
    "$STATS_COUNT" "$STATS_HITTABLE" "$ONEPASSWORD_COUNT" "$ONEPASSWORD_HITTABLE"

FINAL_DIGEST="$(position_digest)"
[[ "$FINAL_DIGEST" == "$BASELINE_DIGEST" ]] || {
    /usr/bin/printf 'error: native position table changed during visibility pilot\n' >&2
    exit 1
}

remote_exec /usr/bin/python3 -c '
import json
import sys
from pathlib import Path
output = Path(sys.argv[1]) / "summary.json"
output.write_text(json.dumps({
    "schema": 1,
    "cyclesPerClass": int(sys.argv[2]),
    "totalCycles": int(sys.argv[2]) * 2,
    "classes": {
        "single-item": {"bundleIdentifier": "com.1password.1password", "itemCount": int(sys.argv[3])},
        "application-group": {"bundleIdentifier": "eu.exelban.Stats", "itemCount": int(sys.argv[4])},
    },
    "positionTableUnchanged": True,
    "verified": True,
}, indent=2, sort_keys=True) + "\n")
' "$EVIDENCE_ROOT" "$CYCLES_PER_CLASS" "$ONEPASSWORD_COUNT" "$STATS_COUNT"

/usr/bin/printf 'P4_VISIBILITY_VERIFIED total=%d\n' "$((CYCLES_PER_CLASS * 2))"
