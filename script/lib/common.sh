#!/usr/bin/env bash

set -euo pipefail

# Gate scripts read repository files with Ruby's File.read/readlines and then
# match against them. Ruby derives its default external encoding from the
# locale, so an unset or C locale makes every one of those reads US-ASCII and
# raises ArgumentError on the first byte above 127. Several tracked files carry
# non-ASCII text (an arrow in the issue template, symbols in KeyCode.swift), so
# the crash is guaranteed rather than incidental, and it surfaces as a bogus
# gate failure rather than as an encoding error. Pin UTF-8 for every child
# process instead of guarding each ruby invocation.
#
# This overrides the caller's locale rather than defaulting to it: an inherited
# LC_ALL=C or LC_CTYPE=C is precisely the condition that breaks the scanners, so
# honouring it would leave the gate broken in the case worth defending against.
# Gate results must not depend on the locale of whichever shell invoked them.
#
# Hardcoding en_US.UTF-8 is not portable: the repository-hygiene lane runs on
# Linux, where a minimal image commonly provides C.UTF-8 and no en_US.UTF-8.
# Exporting a locale the host lacks silently leaves Ruby at US-ASCII, so probe
# for one that exists, and set RUBYOPT as well. RUBYOPT fixes Ruby's external
# encoding directly, independently of any locale, and is inherited by nested
# child processes.
# Capture the locale list rather than piping it into `grep -q`: under
# `set -o pipefail`, grep exits at the first match and the SIGPIPE it delivers
# makes the whole pipeline report failure, so the probe would never fire.
barline_available_locales="$(locale -a 2>/dev/null || true)"
for barline_utf8_locale in en_US.UTF-8 C.UTF-8; do
    if printf '%s\n' "$barline_available_locales" | grep -qix "$barline_utf8_locale"; then
        export LANG="$barline_utf8_locale"
        export LC_ALL="$barline_utf8_locale"
        break
    fi
done
unset barline_utf8_locale barline_available_locales
# Normalize rather than append. Ruby rejects a second, conflicting external
# encoding outright -- `RUBYOPT="-EUS-ASCII -EUTF-8"` aborts every invocation
# with `default_external already set to US-ASCII (RuntimeError)`. Appending
# would therefore break every Ruby lane for anyone whose environment pins
# another encoding. Strip any existing external-encoding option, then set
# exactly one. This also keeps the value stable when common.sh is sourced more
# than once per run, which it is: ci.sh sources it and so does each gate script
# it invokes.
#
# Three option names set the external encoding, each in three spellings:
# attached (-EUS-ASCII), equals (--encoding=US-ASCII), and space-separated
# (--encoding US-ASCII), all of which Ruby accepts from RUBYOPT. The space
# forms must drop the following argument too, or a bare `US-ASCII` token is
# left behind that Ruby still reads as an encoding.
#
# --internal-encoding is deliberately preserved: it does not conflict with a
# later -E, so removing it would discard a setting the caller chose.
barline_normalize_rubyopt() {
    awk '
        BEGIN { out = "" }
        {
            for (i = 1; i <= NF; i++) {
                word = $i
                if (word ~ /^(-E|--encoding|--external-encoding)$/) { i++; continue }
                if (word ~ /^-E./) { continue }
                if (word ~ /^--encoding=/) { continue }
                if (word ~ /^--external-encoding=/) { continue }
                out = (out == "" ? word : out " " word)
            }
        }
        END { print out }
    ' <<<"${1-}"
}
RUBYOPT="$(barline_normalize_rubyopt "${RUBYOPT:-}")"
export RUBYOPT="${RUBYOPT:+$RUBYOPT }-EUTF-8"

barline_die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

barline_require_command() {
    command -v "$1" >/dev/null 2>&1 || barline_die "missing required command '$1'; run ./script/bootstrap.sh"
}

barline_repo_root() {
    git rev-parse --show-toplevel 2>/dev/null || barline_die "run this command inside the Barline repository"
}

barline_xcode_developer_dir() {
    local requested="${1:-}"
    if [[ -n "$requested" ]]; then
        if [[ "$requested" == *.app ]]; then
            requested="${requested}/Contents/Developer"
        fi
        [[ -x "${requested}/usr/bin/xcodebuild" ]] || barline_die "no xcodebuild at ${requested}"
        printf '%s\n' "$requested"
        return
    fi
    xcode-select -p
}

# SwiftPM in Xcode 27 emits a single product object and places the module next
# to it. Earlier toolchains emit per-source objects under BarlineCore.build and
# keep importable modules in a Modules directory. Resolve either layout so the
# standalone runtime probes test the same production sources on both OS lanes.
barline_resolve_core_build_products() {
    local bin_path="$1"
    BARLINE_CORE_OBJECTS=()
    BARLINE_CORE_MODULE_PATH=""

    if [[ -f "$bin_path/BarlineCore.o" && -d "$bin_path/BarlineCore.swiftmodule" ]]; then
        BARLINE_CORE_OBJECTS=("$bin_path/BarlineCore.o")
        BARLINE_CORE_MODULE_PATH="$bin_path"
    else
        shopt -s nullglob
        BARLINE_CORE_OBJECTS=("$bin_path"/BarlineCore.build/*.swift.o)
        shopt -u nullglob
        if ((${#BARLINE_CORE_OBJECTS[@]})) && [[ -d "$bin_path/Modules" ]]; then
            BARLINE_CORE_MODULE_PATH="$bin_path/Modules"
        fi
    fi

    ((${#BARLINE_CORE_OBJECTS[@]})) && [[ -n "$BARLINE_CORE_MODULE_PATH" ]] ||
        barline_die "BarlineCore build products are unavailable for a standalone probe"
}
