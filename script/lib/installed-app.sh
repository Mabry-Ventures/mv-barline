#!/usr/bin/env bash

# Source only. Production gates launch a local build under the installed app's
# bundle identifier, and their cleanup stops processes by name. Pause an
# installed copy for the run and relaunch it afterwards. Process names cannot
# distinguish the installed copy from a local build, so match executable paths.

BARLINE_INSTALLED_APP="${BARLINE_INSTALLED_APP:-/Applications/Barline.app}"
BARLINE_INSTALLED_APP_PAUSED=false

# Prints "pid<TAB>path" for Barline app and helper processes. Tests may supply
# BARLINE_PROCESS_SNAPSHOT in `ps -axo pid=,comm=` format instead of live state.
barline_list_barline_processes() {
    local snapshot
    if [[ -n "${BARLINE_PROCESS_SNAPSHOT+x}" ]]; then
        snapshot="$BARLINE_PROCESS_SNAPSHOT"
    else
        snapshot="$(/bin/ps -axo pid=,comm= 2>/dev/null || true)"
    fi
    /usr/bin/awk '
        match($0, /^ *[0-9]+ /) {
            pid = substr($0, 1, RLENGTH)
            gsub(/ /, "", pid)
            path = substr($0, RLENGTH + 1)
            count = split(path, parts, "/")
            if (parts[count] == "Barline" || parts[count] == "BarlineMenuService") {
                printf "%s\t%s\n", pid, path
            }
        }
    ' <<<"$snapshot"
}

# Prints the app name of each other running menu bar manager. They move a
# local build's control item off the visible menu bar (reported by macOS 27
# at y=1105 while Bartender 7 ran), so runtime smokes cannot find it.
barline_competing_menu_bar_managers() {
    local snapshot
    if [[ -n "${BARLINE_PROCESS_SNAPSHOT+x}" ]]; then
        snapshot="$BARLINE_PROCESS_SNAPSHOT"
    else
        snapshot="$(/bin/ps -axo pid=,comm= 2>/dev/null || true)"
    fi
    /usr/bin/awk '
        match($0, /\/(Bartender[^\/]*|Ice|Hidden Bar|Dozer|Vanilla)\.app\/Contents\/MacOS\//) {
            app = substr($0, RSTART + 1, RLENGTH - 1)
            sub(/\.app\/Contents\/MacOS\/$/, "", app)
            if (!(app in seen)) {
                seen[app] = 1
                print app
            }
        }
    ' <<<"$snapshot"
}

barline_is_installed_app_path() {
    [[ "$1" == "$BARLINE_INSTALLED_APP/Contents/MacOS/Barline" ||
        "$1" == "$BARLINE_INSTALLED_APP/Contents/XPCServices/BarlineMenuService.xpc/Contents/MacOS/BarlineMenuService" ]]
}

barline_installed_app_pids() {
    local pid path
    while IFS=$'\t' read -r pid path; do
        [[ -n "$pid" ]] || continue
        if barline_is_installed_app_path "$path"; then
            printf '%s\n' "$pid"
        fi
    done < <(barline_list_barline_processes)
}

barline_other_barline_pids() {
    local pid path
    while IFS=$'\t' read -r pid path; do
        [[ -n "$pid" ]] || continue
        if ! barline_is_installed_app_path "$path"; then
            printf '%s\n' "$pid"
        fi
    done < <(barline_list_barline_processes)
}

barline_installed_app_running() {
    local pid path
    while IFS=$'\t' read -r pid path; do
        [[ "$path" == "$BARLINE_INSTALLED_APP/Contents/MacOS/Barline" ]] && return 0
    done < <(barline_list_barline_processes)
    return 1
}

barline_terminate_pids() {
    (($#)) || return 0
    local pid alive
    /bin/kill -TERM "$@" >/dev/null 2>&1 || true
    for _ in {1..50}; do
        alive=false
        for pid in "$@"; do
            /bin/kill -0 "$pid" >/dev/null 2>&1 && alive=true
        done
        "$alive" || return 0
        /bin/sleep 0.1
    done
    /bin/kill -KILL "$@" >/dev/null 2>&1 || true
}

barline_pause_installed_app() {
    barline_installed_app_running || return 0
    local pids=() pid
    while IFS= read -r pid; do
        pids+=("$pid")
    done < <(barline_installed_app_pids)
    printf 'Pausing the installed Barline for production gates; it will be relaunched on exit.\n'
    ((${#pids[@]})) && barline_terminate_pids "${pids[@]}"
    BARLINE_INSTALLED_APP_PAUSED=true
}

barline_restore_installed_app() {
    "$BARLINE_INSTALLED_APP_PAUSED" || return 0
    BARLINE_INSTALLED_APP_PAUSED=false
    local pids=() pid
    while IFS= read -r pid; do
        pids+=("$pid")
    done < <(barline_other_barline_pids)
    ((${#pids[@]})) && barline_terminate_pids "${pids[@]}"
    barline_installed_app_running && return 0
    if /usr/bin/open -g "$BARLINE_INSTALLED_APP" >/dev/null 2>&1; then
        printf 'Relaunched the installed Barline.\n'
    else
        printf 'warning: could not relaunch the installed Barline; open it manually.\n' >&2
    fi
}
