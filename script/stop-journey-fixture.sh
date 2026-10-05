#!/usr/bin/env bash
# Stops journey fixtures left running after an installed-candidate run. A
# journey fixture keeps its synthetic status items in the menu bar until it is
# stopped. Fixtures started by XCUITest or the accessibility audit are left
# alone.
#
# usage: stop-journey-fixture.sh [--list]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=script/lib/installed-app.sh
source "$SCRIPT_DIR/lib/installed-app.sh"
# shellcheck source=script/lib/journey-fixture.sh
source "$SCRIPT_DIR/lib/journey-fixture.sh"

LIST_ONLY=false
case "${1:-}" in
    "") ;;
    --list) LIST_ONLY=true ;;
    *) printf 'usage: %s [--list]\n' "$0" >&2; exit 2 ;;
esac

pids=()
while IFS= read -r pid; do
    pids+=("$pid")
done < <(barline_journey_fixture_pids)

if ((${#pids[@]} == 0)); then
    printf 'No journey fixture is running.\n'
    exit 0
fi
if "$LIST_ONLY"; then
    for pid in "${pids[@]}"; do
        printf '%s\t%s\n' "$pid" "$(/bin/ps -o etime= -p "$pid" | /usr/bin/tr -d ' ')"
    done
    exit 0
fi
printf 'Stopping %d journey fixture(s): %s\n' "${#pids[@]}" "${pids[*]}"
barline_terminate_pids "${pids[@]}"
printf 'Stopped.\n'
