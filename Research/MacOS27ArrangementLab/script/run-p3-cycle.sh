#!/usr/bin/env bash
set -euo pipefail

HOST="${BARLINE_LAB_HOST:-cplcodex01}"
IDENTITY="${BARLINE_LAB_SSH_IDENTITY:-}"
SOURCE_RECEIPT="${1:-}"
SOURCE_TOKEN="${2:-}"
DESTINATION_RECEIPT="${3:-}"
DESTINATION_TOKEN="${4:-}"
PLACEMENT="${5:-}"
PROBE_OUTPUT="${6:-}"
CYCLE_OUTPUT="${7:-}"

[[ "$SOURCE_RECEIPT" == /* && "$DESTINATION_RECEIPT" == /* && \
   "$PROBE_OUTPUT" == /* && "$CYCLE_OUTPUT" == /* ]] || {
    /usr/bin/printf 'usage: %s source-receipt source-token destination-receipt destination-token before|after probe-output cycle-output\n' "$0" >&2
    exit 2
}
[[ "$PLACEMENT" == before || "$PLACEMENT" == after ]] || {
    /usr/bin/printf 'error: placement must be before or after\n' >&2
    exit 2
}
[[ "$PROBE_OUTPUT" != "$CYCLE_OUTPUT" ]] || {
    /usr/bin/printf 'error: probe and cycle outputs must differ\n' >&2
    exit 2
}

SSH=(/usr/bin/ssh -o BatchMode=yes)
if [[ -n "$IDENTITY" ]]; then
    SSH+=(-i "$IDENTITY")
fi
REMOTE="$HOST"
TEMP_DIRECTORY="$(/usr/bin/mktemp -d /tmp/barline-p3-cycle.XXXXXX)"
PRIOR_FRONTMOST_BUNDLE=""
SCREEN_SHARING_ACTIVATED=false
cleanup() {
    if [[ "$SCREEN_SHARING_ACTIVATED" == true && -n "$PRIOR_FRONTMOST_BUNDLE" ]]; then
        /usr/bin/osascript -e "tell application id \"$PRIOR_FRONTMOST_BUNDLE\" to activate" >/dev/null 2>&1 || true
    fi
    /bin/rm -rf "$TEMP_DIRECTORY"
}
trap cleanup EXIT
LOCAL_PROBE="$TEMP_DIRECTORY/probe.json"
LOCAL_CYCLE="$TEMP_DIRECTORY/cycle.plist"

remote_exec() {
    local command_string=""
    local quoted
    for argument in "$@"; do
        printf -v quoted '%q' "$argument"
        command_string+="$quoted "
    done
    "${SSH[@]}" "$REMOTE" "$command_string"
}

remote_python_value() {
    local receipt="$1"
    local token="$2"
    remote_exec /usr/bin/python3 -c '
import json
import sys
receipt = json.load(open(sys.argv[1]))
matches = [item for item in receipt["items"] if item["token"] == sys.argv[2]]
assert len(matches) == 1
print(matches[0]["activations"])
' "$receipt" "$token"
}

# The expansion must happen on CPLCODEX01, not on the coordinating host.
# shellcheck disable=SC2016
remote_exec /bin/bash -lc 'exec "$HOME/Applications/BarlineArrangementLab/script/run-synthetic-move.sh" "$@"' barline-cycle \
    "$SOURCE_RECEIPT" "$SOURCE_TOKEN" \
    "$DESTINATION_RECEIPT" "$DESTINATION_TOKEN" \
    "$PLACEMENT" "$PROBE_OUTPUT" >/dev/null
remote_exec /bin/cat "$PROBE_OUTPUT" > "$LOCAL_PROBE"

DISPOSITION="$(/usr/bin/plutil -extract disposition raw "$LOCAL_PROBE")"
[[ "$DISPOSITION" == movePlacementVerified ]] || {
    /usr/bin/printf 'error: placement probe returned %s\n' "$DISPOSITION" >&2
    /usr/bin/plutil -p "$LOCAL_PROBE" >&2
    exit 1
}
[[ "$(/usr/bin/plutil -extract buttonCleanupVerified raw "$LOCAL_PROBE")" == true ]] || {
    /usr/bin/printf 'error: placement probe did not prove button cleanup\n' >&2
    exit 1
}
[[ "$(/usr/bin/plutil -extract unrelatedOrderPreserved raw "$LOCAL_PROBE")" == true ]] || {
    /usr/bin/printf 'error: placement probe disturbed unrelated order\n' >&2
    exit 1
}

REMOTE_X="$(/usr/bin/plutil -extract sourceFrameAfter.x raw "$LOCAL_PROBE")"
REMOTE_Y="$(/usr/bin/plutil -extract sourceFrameAfter.y raw "$LOCAL_PROBE")"
REMOTE_WIDTH="$(/usr/bin/plutil -extract sourceFrameAfter.width raw "$LOCAL_PROBE")"
REMOTE_HEIGHT="$(/usr/bin/plutil -extract sourceFrameAfter.height raw "$LOCAL_PROBE")"
ACTIVATION_FRAME_SOURCE="placementProbe"
SOURCE_ITEM_COUNT="$(remote_exec /usr/bin/python3 -c \
    'import json,sys; print(len(json.load(open(sys.argv[1]))["items"]))' "$SOURCE_RECEIPT")"
if [[ "$SOURCE_ITEM_COUNT" -eq 1 ]]; then
    ACTIVATION_OBSERVATION="${PROBE_OUTPUT%.json}-activation-observation.json"
    # The expansion must happen on CPLCODEX01, not on the coordinating host.
    # shellcheck disable=SC2016
    remote_exec /bin/bash -lc \
        'exec "$HOME/Applications/BarlineArrangementLab/script/observe-fixture.sh" "$@"' \
        barline-cycle "$SOURCE_RECEIPT" "$ACTIVATION_OBSERVATION" >/dev/null
    remote_exec /bin/cat "$ACTIVATION_OBSERVATION" > "$TEMP_DIRECTORY/activation-observation.json"
    REMOTE_X="$(/usr/bin/plutil -extract items.0.frame.x raw "$TEMP_DIRECTORY/activation-observation.json")"
    REMOTE_Y="$(/usr/bin/plutil -extract items.0.frame.y raw "$TEMP_DIRECTORY/activation-observation.json")"
    REMOTE_WIDTH="$(/usr/bin/plutil -extract items.0.frame.width raw "$TEMP_DIRECTORY/activation-observation.json")"
    REMOTE_HEIGHT="$(/usr/bin/plutil -extract items.0.frame.height raw "$TEMP_DIRECTORY/activation-observation.json")"
    ACTIVATION_FRAME_SOURCE="freshSingleItemObservation"
fi
REMOTE_CENTER_X="$(/usr/bin/awk -v x="$REMOTE_X" -v w="$REMOTE_WIDTH" 'BEGIN { printf "%.6f", x + w / 2 }')"
REMOTE_CENTER_Y="$(/usr/bin/awk -v y="$REMOTE_Y" -v h="$REMOTE_HEIGHT" 'BEGIN { printf "%.6f", y + h / 2 }')"

REMOTE_DISPLAY_X="$(/usr/bin/plutil -extract sourceDisplayFrame.x raw "$LOCAL_PROBE")"
REMOTE_DISPLAY_Y="$(/usr/bin/plutil -extract sourceDisplayFrame.y raw "$LOCAL_PROBE")"
REMOTE_DISPLAY_WIDTH="$(/usr/bin/plutil -extract sourceDisplayFrame.width raw "$LOCAL_PROBE")"
REMOTE_DISPLAY_HEIGHT="$(/usr/bin/plutil -extract sourceDisplayFrame.height raw "$LOCAL_PROBE")"

PRIOR_FRONTMOST_BUNDLE="$(/usr/bin/osascript <<'APPLESCRIPT'
tell application "System Events"
  return bundle identifier of first application process whose frontmost is true
end tell
APPLESCRIPT
)"
/usr/bin/osascript -e 'tell application "Screen Sharing" to activate'
SCREEN_SHARING_ACTIVATED=true
SCREEN_SHARING_FRONTMOST=false
for _ in {1..20}; do
    if [[ "$(/usr/bin/osascript <<'APPLESCRIPT'
tell application "System Events" to return frontmost of process "Screen Sharing"
APPLESCRIPT
)" == true ]]; then
        SCREEN_SHARING_FRONTMOST=true
        break
    fi
    /bin/sleep 0.05
    /usr/bin/osascript -e 'tell application "Screen Sharing" to activate' >/dev/null
done
[[ "$SCREEN_SHARING_FRONTMOST" == true ]] || {
    /usr/bin/printf 'error: Screen Sharing did not become frontmost\n' >&2
    exit 1
}
SHARED_FRAME="$(/usr/bin/osascript <<'APPLESCRIPT'
tell application "System Events"
  tell process "Screen Sharing"
    set targetWindows to every window whose name contains "CPLCODEX01"
    if (count of targetWindows) is not 1 then error "expected exactly one CPLCODEX01 window"
    set sharedScreen to UI element 1 of item 1 of targetWindows
    return {position of sharedScreen, size of sharedScreen}
  end tell
end tell
APPLESCRIPT
)"
IFS=', ' read -r SHARED_X SHARED_Y SHARED_WIDTH SHARED_HEIGHT <<< "$SHARED_FRAME"

ASPECT_DELTA="$(/usr/bin/awk \
    -v rw="$REMOTE_DISPLAY_WIDTH" -v rh="$REMOTE_DISPLAY_HEIGHT" \
    -v sw="$SHARED_WIDTH" -v sh="$SHARED_HEIGHT" \
    'BEGIN { d = rw / rh - sw / sh; if (d < 0) d = -d; printf "%.6f", d }')"
/usr/bin/awk -v d="$ASPECT_DELTA" 'BEGIN { exit !(d <= 0.01) }' || {
    /usr/bin/printf 'error: Screen Sharing aspect ratio does not match CPLCODEX01\n' >&2
    exit 1
}

LOCAL_X="$(/usr/bin/awk \
    -v sx="$SHARED_X" -v sw="$SHARED_WIDTH" -v rx="$REMOTE_CENTER_X" -v rw="$REMOTE_DISPLAY_WIDTH" \
    -v rdx="$REMOTE_DISPLAY_X" \
    'BEGIN { printf "%.6f", sx + (rx - rdx) / rw * sw }')"
LOCAL_Y="$(/usr/bin/awk \
    -v sy="$SHARED_Y" -v sh="$SHARED_HEIGHT" -v ry="$REMOTE_CENTER_Y" -v rh="$REMOTE_DISPLAY_HEIGHT" \
    -v rdy="$REMOTE_DISPLAY_Y" \
    'BEGIN { printf "%.6f", sy + (ry - rdy) / rh * sh }')"

ACTIVATION_BEFORE="$(remote_python_value "$SOURCE_RECEIPT" "$SOURCE_TOKEN")"
/usr/bin/swift -e '
import CoreGraphics
import Foundation
let point = CGPoint(x: Double(CommandLine.arguments[1])!, y: Double(CommandLine.arguments[2])!)
let source = CGEventSource(stateID: .hidSystemState)
guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
      let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
else { exit(2) }
down.setIntegerValueField(.mouseEventClickState, value: 1)
up.setIntegerValueField(.mouseEventClickState, value: 1)
down.post(tap: .cghidEventTap)
Thread.sleep(forTimeInterval: 0.08)
up.post(tap: .cghidEventTap)
Thread.sleep(forTimeInterval: 0.2)
' "$LOCAL_X" "$LOCAL_Y"
/usr/bin/osascript -e "tell application id \"$PRIOR_FRONTMOST_BUNDLE\" to activate" >/dev/null 2>&1 || true
SCREEN_SHARING_ACTIVATED=false

ACTIVATION_AFTER="$ACTIVATION_BEFORE"
for _ in {1..30}; do
    ACTIVATION_AFTER="$(remote_python_value "$SOURCE_RECEIPT" "$SOURCE_TOKEN")"
    [[ "$ACTIVATION_AFTER" -gt "$ACTIVATION_BEFORE" ]] && break
    /bin/sleep 0.1
done
ACTIVATION_DELTA="$((ACTIVATION_AFTER - ACTIVATION_BEFORE))"
[[ "$ACTIVATION_DELTA" -eq 1 ]] || {
    /usr/bin/printf 'error: host-forwarded activation delta was %s, expected 1\n' "$ACTIVATION_DELTA" >&2
    exit 1
}

/usr/bin/plutil -create xml1 "$LOCAL_CYCLE"
/usr/bin/plutil -insert schema -integer 1 "$LOCAL_CYCLE"
/usr/bin/plutil -insert disposition -string cycleVerified "$LOCAL_CYCLE"
/usr/bin/plutil -insert sourceToken -string "$SOURCE_TOKEN" "$LOCAL_CYCLE"
/usr/bin/plutil -insert destinationToken -string "$DESTINATION_TOKEN" "$LOCAL_CYCLE"
/usr/bin/plutil -insert placement -string "$PLACEMENT" "$LOCAL_CYCLE"
/usr/bin/plutil -insert activationMethod -string screenSharingForwardedPhysicalClick "$LOCAL_CYCLE"
/usr/bin/plutil -insert activationFrameSource -string "$ACTIVATION_FRAME_SOURCE" "$LOCAL_CYCLE"
/usr/bin/plutil -insert activationDelta -integer "$ACTIVATION_DELTA" "$LOCAL_CYCLE"
/usr/bin/plutil -insert probeResultSHA256 -string "$(/usr/bin/shasum -a 256 "$LOCAL_PROBE" | /usr/bin/awk '{print $1}')" "$LOCAL_CYCLE"
/usr/bin/plutil -insert remoteItemCenter -dictionary "$LOCAL_CYCLE"
/usr/bin/plutil -insert remoteItemCenter.x -float "$REMOTE_CENTER_X" "$LOCAL_CYCLE"
/usr/bin/plutil -insert remoteItemCenter.y -float "$REMOTE_CENTER_Y" "$LOCAL_CYCLE"
/usr/bin/plutil -insert sharedScreenFrame -dictionary "$LOCAL_CYCLE"
/usr/bin/plutil -insert sharedScreenFrame.x -float "$SHARED_X" "$LOCAL_CYCLE"
/usr/bin/plutil -insert sharedScreenFrame.y -float "$SHARED_Y" "$LOCAL_CYCLE"
/usr/bin/plutil -insert sharedScreenFrame.width -float "$SHARED_WIDTH" "$LOCAL_CYCLE"
/usr/bin/plutil -insert sharedScreenFrame.height -float "$SHARED_HEIGHT" "$LOCAL_CYCLE"
/usr/bin/plutil -convert json "$LOCAL_CYCLE"
remote_exec /usr/bin/tee "$CYCLE_OUTPUT" < "$LOCAL_CYCLE" >/dev/null
/usr/bin/printf '%s\n' "$CYCLE_OUTPUT"
