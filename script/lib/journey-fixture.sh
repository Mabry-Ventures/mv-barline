#!/usr/bin/env bash

# Source only. Journey fixtures are started detached by start-journey-fixture.sh
# and keep their synthetic status items ("BF Native", "BF Popover") in the menu
# bar until they are stopped. These helpers find them without touching the
# fixtures that XCUITest or the accessibility audit start for themselves.

# Succeeds when a `ps eww` command line (the command followed by its
# environment) belongs to a journey fixture started by start-journey-fixture.sh.
# Each environment entry must be a whole space-delimited token, so a longer
# variable name or value never matches. XCUITest also runs its Native and
# Popover tests in journey mode, but always with the qualification window
# (BARLINE_FIXTURE_QUALIFICATION_WINDOW=1), which the launcher never sets;
# those fixtures belong to the running test and are not matched.
barline_is_journey_fixture_line() {
    local padded=" $1 "
    [[ "$padded" == *" BARLINE_FIXTURE_MODE=journey "* &&
        "$padded" != *" BARLINE_FIXTURE_QUALIFICATION_WINDOW=1 "* ]]
}

# Succeeds when the BarlineFixture.app at $1 was built with the lifetime
# setting. An older build ignores BARLINE_FIXTURE_LIFETIME_SECONDS and would
# never quit on its own. Debug builds keep their code in a sibling dylib, so
# search the whole MacOS directory.
barline_fixture_supports_lifetime() {
    /usr/bin/grep -rqa BARLINE_FIXTURE_LIFETIME_SECONDS "$1/Contents/MacOS" 2>/dev/null
}

# Prints the pid of every running journey fixture.
barline_journey_fixture_pids() {
    local pid line
    while IFS= read -r pid; do
        [[ -n "$pid" ]] || continue
        line="$(/bin/ps eww -o command= -p "$pid" 2>/dev/null || true)"
        if barline_is_journey_fixture_line "$line"; then
            printf '%s\n' "$pid"
        fi
    done < <(/usr/bin/pgrep -x BarlineFixture || true)
}
