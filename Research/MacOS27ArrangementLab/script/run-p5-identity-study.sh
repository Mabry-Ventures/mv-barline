#!/usr/bin/env bash
set -euo pipefail

HOST="${BARLINE_LAB_HOST:-cplcodex01}"
IDENTITY="${BARLINE_LAB_SSH_IDENTITY:-}"
EVIDENCE_ROOT="${1:-}"
[[ "$EVIDENCE_ROOT" == /* ]] || {
    /usr/bin/printf 'usage: %s /absolute/remote-evidence-directory\n' "$0" >&2
    exit 2
}

SSH=(/usr/bin/ssh -o BatchMode=yes)
if [[ -n "$IDENTITY" ]]; then
    SSH+=(-i "$IDENTITY")
fi
ALIAS_KEY="$(/usr/bin/openssl rand -hex 32)"
AUTOSAVE_REVISION="p5$(/usr/bin/uuidgen | /usr/bin/tr -d - | /usr/bin/cut -c1-10)"

remote_exec() {
    local command_string=""
    local quoted
    for argument in "$@"; do
        printf -v quoted '%q' "$argument"
        command_string+="$quoted "
    done
    "${SSH[@]}" "$HOST" "$command_string"
}

stop_fixture() {
    # Process expansion belongs to CPLCODEX01.
    # shellcheck disable=SC2016
    remote_exec /bin/bash -lc '
identifiers="$(/usr/bin/pgrep -x BarlineIdentityFixture || true)"
[[ -z "$identifiers" ]] || /bin/kill $identifiers
for _ in {1..100}; do
    /usr/bin/pgrep -x BarlineIdentityFixture >/dev/null || exit 0
    /bin/sleep 0.1
done
exit 1
'
}
trap 'stop_fixture >/dev/null 2>&1 || true' EXIT

launch_case() {
    local case_name="$1"
    local revision="$2"
    local identifier_mode="$3"
    local title_mode="$4"
    local creation_order="$5"
    local directory="$EVIDENCE_ROOT/$case_name"
    local receipt="$directory/receipt.json"
    remote_exec /bin/mkdir -p "$directory"
    # Expansion belongs to CPLCODEX01.
    # shellcheck disable=SC2016
    remote_exec /bin/bash -lc '
set -euo pipefail
receipt="$1"
revision="$2"
identifier_mode="$3"
title_mode="$4"
creation_order="$5"
app="$HOME/Applications/BarlineArrangementLab/dist/BarlineIdentityFixture.app"
session="$(/usr/bin/uuidgen)"
[[ ! -e "$receipt" ]]
/usr/bin/open -g -j -n "$app" \
    --env BARLINE_LAB_PUBLISHER_KIND=multi \
    --env "BARLINE_LAB_SESSION=$session" \
    --env BARLINE_LAB_FIXTURE_VARIANT=unique-labels \
    --env "BARLINE_LAB_FIXTURE_RECEIPT=$receipt" \
    --env "BARLINE_LAB_P5_AUTOSAVE_REVISION=$revision" \
    --env "BARLINE_LAB_P5_IDENTIFIER_MODE=$identifier_mode" \
    --env "BARLINE_LAB_P5_TITLE_MODE=$title_mode" \
    --env "BARLINE_LAB_P5_CREATION_ORDER=$creation_order"
for _ in {1..100}; do
    /usr/bin/python3 -c '\''
import json, sys
value = json.load(open(sys.argv[1]))
assert value["sequence"] >= 2
assert len(value["items"]) == 3
assert all(item.get("frame") for item in value["items"])
'\'' "$receipt" >/dev/null 2>&1 && exit 0
    /bin/sleep 0.1
done
exit 1
' barline-p5 "$receipt" "$revision" "$identifier_mode" "$title_mode" "$creation_order"
    /bin/sleep 0.5
}

observe_case() {
    local case_name="$1"
    local receipt="$EVIDENCE_ROOT/$case_name/receipt.json"
    local observation="$EVIDENCE_ROOT/$case_name/observation.json"
    # Expansion belongs to CPLCODEX01.
    # shellcheck disable=SC2016
    remote_exec /bin/bash -lc '
set -euo pipefail
receipt="$1"
observation="$2"
observer="$HOME/Applications/BarlineArrangementLab/dist/BarlineArrangementObserver.app"
/usr/bin/open -g -j -n "$observer" --args observe "$receipt" "$observation"
for _ in {1..100}; do
    [[ -s "$observation" ]] && break
    /bin/sleep 0.1
done
[[ "$(/usr/bin/plutil -extract complete raw "$observation")" == true ]]
' barline-p5 "$receipt" "$observation"
}

move_case() {
    local case_name="$1"
    local receipt="$EVIDENCE_ROOT/$case_name/receipt.json"
    local report="$EVIDENCE_ROOT/$case_name/native-move.json"
    local placement
    placement="$(remote_exec /usr/bin/python3 -c '
import json
import sys
value = json.load(open(sys.argv[1]))
items = {item["token"]: item["frame"] for item in value["items"]}
source = items["beta"]["x"] + items["beta"]["width"] / 2
destination = items["gamma"]["x"] + items["gamma"]["width"] / 2
assert source != destination
print("after" if source < destination else "before")
' "$receipt")"
    # Expansion belongs to CPLCODEX01.
    # shellcheck disable=SC2016
    remote_exec /bin/bash -lc '
set -euo pipefail
script="$HOME/Applications/BarlineArrangementLab/script/run-synthetic-move.sh"
receipt="$1"
placement="$2"
report="$3"
"$script" "$receipt" beta "$receipt" gamma "$placement" "$report" >/dev/null
[[ "$(/usr/bin/plutil -extract disposition raw "$report")" == movePlacementVerified ]]
' barline-p5 "$receipt" "$placement" "$report"
}

capture_table() {
    local case_name="$1"
    local receipt="$EVIDENCE_ROOT/$case_name/receipt.json"
    local output="$EVIDENCE_ROOT/$case_name/table.json"
    remote_exec /usr/bin/python3 -c '
import hashlib
import hmac
import json
import plistlib
import sys

receipt_path, output_path, alias_key, case_name = sys.argv[1:]
receipt = json.load(open(receipt_path))
plist_path = (
    __import__("pathlib").Path.home()
    / "Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar.plist"
)
with plist_path.open("rb") as handle:
    positions = plistlib.load(handle).get("TrailingItemPreferredPositions", {})
fixture_records = {
    key: value for key, value in positions.items()
    if "BarlineIdentityFixture::" in key
}
expected_suffixes = {item["autosaveName"] for item in receipt["items"]}
current_records = {
    key: value for key, value in fixture_records.items()
    if key.split("::", 1)[-1] in expected_suffixes
}

def alias(key):
    return hmac.new(bytes.fromhex(alias_key), key.encode(), hashlib.sha256).hexdigest()[:20]

mappings = []
for item in receipt["items"]:
    matches = [
        (key, value) for key, value in current_records.items()
        if key.split("::", 1)[-1] == item["autosaveName"]
    ]
    mappings.append({
        "token": item["token"],
        "generation": item["generation"],
        "creationOrdinal": item["creationOrdinal"],
        "accessibilityIdentifierPresent": bool(item.get("accessibilityIdentifier")),
        "titlePresent": bool(item.get("title")),
        "exactAutosaveSuffixMatchCount": len(matches),
        "recordAlias": alias(matches[0][0]) if len(matches) == 1 else None,
        "position": matches[0][1] if len(matches) == 1 else None,
    })
matched_keys = {
    key for item in receipt["items"] for key in current_records
    if key.split("::", 1)[-1] == item["autosaveName"]
}
document = {
    "schema": 1,
    "case": case_name,
    "receiptSequence": receipt["sequence"],
    "fixtureRecordCount": len(current_records),
    "historicalFixtureRecordCount": len(fixture_records) - len(current_records),
    "allExpectedMappedExactlyOnce": all(
        item["exactAutosaveSuffixMatchCount"] == 1 for item in mappings
    ),
    "fixtureRecordAliases": sorted(alias(key) for key in current_records),
    "mappings": mappings,
    "unmatchedFixtureRecordAliases": sorted(
        alias(key) for key in current_records if key not in matched_keys
    ),
}
with open(output_path, "w") as handle:
    json.dump(document, handle, indent=2, sort_keys=True)
    handle.write("\n")
' "$receipt" "$output" "$ALIAS_KEY" "$case_name"
}

run_case() {
    local case_name="$1"
    local revision="$2"
    local identifier_mode="$3"
    local title_mode="$4"
    local creation_order="$5"
    stop_fixture
    launch_case "$case_name" "$revision" "$identifier_mode" "$title_mode" "$creation_order"
    observe_case "$case_name"
    move_case "$case_name"
    stop_fixture
    /bin/sleep 0.5
    capture_table "$case_name"
}

remote_exec /bin/mkdir -p "$EVIDENCE_ROOT"
run_case baseline "$AUTOSAVE_REVISION" normal normal normal
run_case identifier-changed "$AUTOSAVE_REVISION" changed normal normal
run_case identifier-absent "$AUTOSAVE_REVISION" absent normal normal
run_case title-changed "$AUTOSAVE_REVISION" normal changed normal
run_case title-duplicate "$AUTOSAVE_REVISION" normal duplicate normal
run_case title-absent "$AUTOSAVE_REVISION" normal absent normal
run_case creation-reversed "$AUTOSAVE_REVISION" normal normal reversed

stop_fixture
launch_case lifecycle-recreated "$AUTOSAVE_REVISION" normal normal normal
remote_exec /usr/bin/swift -e '
import Foundation
DistributedNotificationCenter.default().post(
    name: Notification.Name("com.mabryventures.Barline.IdentityFixture.recreate-beta"),
    object: nil
)
Thread.sleep(forTimeInterval: 0.8)
'
observe_case lifecycle-recreated
move_case lifecycle-recreated
stop_fixture
/bin/sleep 0.5
capture_table lifecycle-recreated

run_case autosave-changed "${AUTOSAVE_REVISION}b" normal normal normal
stop_fixture

remote_exec /usr/bin/python3 -c '
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
same_cases = [
    "identifier-changed", "identifier-absent", "title-changed",
    "title-duplicate", "title-absent", "creation-reversed", "lifecycle-recreated",
]

def aliases(case):
    value = json.load(open(root / case / "table.json"))
    assert value["fixtureRecordCount"] == 3, value
    return value["fixtureRecordAliases"]

baseline = aliases("baseline")
stable = {case: aliases(case) == baseline for case in same_cases}
autosave = json.load(open(root / "autosave-changed" / "table.json"))
assert autosave["fixtureRecordCount"] in (0, 3), autosave
autosave_changed_records = (
    autosave["fixtureRecordCount"] == 3
    and autosave["fixtureRecordAliases"] != baseline
)
document = {
    "schema": 1,
    "stableWhenAXIdentifierChanges": stable["identifier-changed"],
    "stableWhenAXIdentifierIsAbsent": stable["identifier-absent"],
    "stableWhenTitleChanges": stable["title-changed"],
    "stableWhenTitlesDuplicate": stable["title-duplicate"],
    "stableWhenTitleIsAbsent": stable["title-absent"],
    "stableWhenCreationOrderReverses": stable["creation-reversed"],
    "stableWhenItemIsRecreated": stable["lifecycle-recreated"],
    "changesWhenAutosaveNameChanges": autosave_changed_records,
    "autosaveChangedExactRecordCount": autosave["fixtureRecordCount"],
    "classification": (
        "autosave-name-influenced-but-not-generally-resolvable-from-ax"
        if autosave_changed_records
        else "opaque-publisher-history-not-generally-resolvable-from-ax"
    ),
    "verified": all(stable.values()) and autosave["fixtureRecordCount"] in (0, 3),
}
with open(root / "summary.json", "w") as handle:
    json.dump(document, handle, indent=2, sort_keys=True)
    handle.write("\n")
assert document["verified"], document
' "$EVIDENCE_ROOT"

/usr/bin/printf 'P5_IDENTITY_VERIFIED classification=not-generally-resolvable-from-ax\n'
