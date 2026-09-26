#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BARLINE_INSTALLED_APP=/Applications/Barline.app
# shellcheck source=script/lib/installed-app.sh
source "$SCRIPT_DIR/lib/installed-app.sh"

fail() {
    printf 'installed-app pause: %s\n' "$*" >&2
    exit 1
}

joined() {
    "$@" | /usr/bin/tr '\n' ' '
}

BARLINE_PROCESS_SNAPSHOT="$(cat <<'SNAPSHOT'
  101 /Applications/Barline.app/Contents/MacOS/Barline
  102 /Applications/Barline.app/Contents/XPCServices/BarlineMenuService.xpc/Contents/MacOS/BarlineMenuService
  201 /private/tmp/barline-ci-501-abc/DerivedData/Build/Products/Release/Barline.app/Contents/MacOS/Barline
  202 /private/tmp/barline-ci-501-abc/DerivedData/Build/Products/Release/Barline.app/Contents/XPCServices/BarlineMenuService.xpc/Contents/MacOS/BarlineMenuService
  301 /Applications/Barline.app.old/Contents/MacOS/Barline
  302 /Applications/Barline Beta.app/Contents/MacOS/Barline
  401 /Applications/Barline.app/Contents/Extensions/BarlineIntents.appex/Contents/MacOS/BarlineIntents
  501 /usr/libexec/Barlineish
SNAPSHOT
)"

[[ "$(joined barline_installed_app_pids)" == "101 102 " ]] || fail "installed copy match: $(joined barline_installed_app_pids)"
[[ "$(joined barline_other_barline_pids)" == "201 202 301 302 " ]] || fail "other copies match: $(joined barline_other_barline_pids)"
barline_installed_app_running || fail "running installed app was not detected"

BARLINE_PROCESS_SNAPSHOT="  102 /Applications/Barline.app/Contents/XPCServices/BarlineMenuService.xpc/Contents/MacOS/BarlineMenuService"
if barline_installed_app_running; then
    fail "helper alone was treated as a running installed app"
fi

BARLINE_PROCESS_SNAPSHOT="  201 /private/tmp/barline-ci-501-abc/DerivedData/Build/Products/Release/Barline.app/Contents/MacOS/Barline"
if barline_installed_app_running; then
    fail "local build was treated as the installed app"
fi
[[ -z "$(barline_installed_app_pids)" ]] || fail "local build matched the installed copy"

BARLINE_PROCESS_SNAPSHOT=""
if barline_installed_app_running; then
    fail "empty process list reported a running installed app"
fi
[[ -z "$(barline_other_barline_pids)" ]] || fail "empty process list produced pids"

BARLINE_INSTALLED_APP_PAUSED=false
BARLINE_PROCESS_SNAPSHOT="  101 /Applications/Barline.app/Contents/MacOS/Barline"
barline_restore_installed_app || fail "restore without a pause must be a no-op"

BARLINE_PROCESS_SNAPSHOT="$(cat <<'SNAPSHOT'
  601 /Applications/Bartender 7.app/Contents/MacOS/Bartender 7
  602 /usr/bin/perl /Applications/Bartender 7.app/Contents/Resources/NotchBar_BartenderMusic.bundle/Contents/Resources/x
  603 /Applications/Ice.app/Contents/MacOS/Ice
  604 /Applications/Barline.app/Contents/MacOS/Barline
  605 /Applications/Icebox.app/Contents/MacOS/Icebox
  606 /Applications/Hidden Bar.app/Contents/MacOS/Hidden Bar
SNAPSHOT
)"
[[ "$(joined barline_competing_menu_bar_managers)" == "Bartender 7 Ice Hidden Bar " ]] ||
    fail "menu bar managers match: $(joined barline_competing_menu_bar_managers)"
BARLINE_PROCESS_SNAPSHOT="  604 /Applications/Barline.app/Contents/MacOS/Barline"
[[ -z "$(barline_competing_menu_bar_managers)" ]] || fail "Barline alone was reported as a competing manager"

printf 'Installed-app pause: exact-path matching passed 12 positive/negative cases without stopping processes.\n'
