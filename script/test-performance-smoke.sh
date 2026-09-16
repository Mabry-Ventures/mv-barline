#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=script/lib/identity.sh
source "$ROOT/script/lib/identity.sh"
MODULE_CACHE="${TMPDIR:-/tmp}/barline-performance-module-cache"
BINARY="${TMPDIR:-/tmp}/barline-shelf-responsiveness"
PREFERENCE_DOMAIN=""
PREFERENCE_KEY="UseBarlineShelf"
ORIGINAL_PREFERENCE="__missing__"
REUSE_RUNNING=false
OUTPUT_PATH=""
PERFORMANCE_SOURCE_DIR=""
PROBE="${BARLINE_PERFORMANCE_PROBE:-runtime-smoke}"
BUILD_CONFIGURATION="${BARLINE_BUILD_CONFIGURATION:-Debug}"

usage() {
    printf 'usage: %s [--reuse-running] [--probe runtime-smoke|status-item-click|apple-event-reopen] [--output PATH]\n' "$0" >&2
}

while (($#)); do
    case "$1" in
        --reuse-running) REUSE_RUNNING=true ;;
        --probe)
            (($# >= 2)) || { usage; exit 2; }
            PROBE="$2"
            shift
            ;;
        --output)
            (($# >= 2)) || { usage; exit 2; }
            OUTPUT_PATH="$2"
            shift
            ;;
        -h|--help) usage; exit 0 ;;
        *) usage; exit 2 ;;
    esac
    shift
done

if [[ -n "${BARLINE_EVIDENCE_OUTPUT:-}" ]] && ! "$REUSE_RUNNING"; then
    printf 'error: installed evidence requires --reuse-running\n' >&2
    exit 2
fi

[[ "$PROBE" == runtime-smoke || "$PROBE" == status-item-click || "$PROBE" == apple-event-reopen ]] || {
    usage
    exit 2
}
if [[ "$PROBE" == status-item-click && -z "${BARLINE_BUILD_CONFIGURATION:-}" ]]; then
    BUILD_CONFIGURATION="Release"
fi
[[ "$BUILD_CONFIGURATION" == Debug || "$BUILD_CONFIGURATION" == Release ]] || {
    printf 'error: BARLINE_BUILD_CONFIGURATION must be Debug or Release\n' >&2
    exit 2
}

if [[ -n "${BARLINE_APP_BUNDLE_IDENTIFIER:-}" ]]; then
    barline_validate_bundle_identifier "$BARLINE_APP_BUNDLE_IDENTIFIER" || {
        printf 'error: inherited BARLINE_APP_BUNDLE_IDENTIFIER is invalid\n' >&2
        exit 1
    }
    PREFERENCE_DOMAIN="$BARLINE_APP_BUNDLE_IDENTIFIER"
else
    PREFERENCE_DOMAIN="$(barline_resolve_app_bundle_identifier "$ROOT" "$BUILD_CONFIGURATION")"
fi

if ORIGINAL_PREFERENCE_VALUE="$(/usr/bin/defaults read "$PREFERENCE_DOMAIN" "$PREFERENCE_KEY" 2>/dev/null)"; then
    ORIGINAL_PREFERENCE="$ORIGINAL_PREFERENCE_VALUE"
fi

cleanup() {
    if [[ -n "$PERFORMANCE_SOURCE_DIR" ]]; then
        /bin/rm -f "$PERFORMANCE_SOURCE_DIR/main.swift"
        /bin/rmdir "$PERFORMANCE_SOURCE_DIR"
    fi
    # Reused candidates never changed this preference; do not overwrite a
    # user's concurrent choice during cleanup.
    if "$REUSE_RUNNING"; then return; fi
    if ! "$REUSE_RUNNING"; then
        /usr/bin/pkill -x Barline >/dev/null 2>&1 || true
        /usr/bin/pkill -x BarlineMenuService >/dev/null 2>&1 || true
    fi
    if [[ "$ORIGINAL_PREFERENCE" == "__missing__" ]]; then
        /usr/bin/defaults delete "$PREFERENCE_DOMAIN" "$PREFERENCE_KEY" >/dev/null 2>&1 || true
    else
        if [[ "$ORIGINAL_PREFERENCE" == "1" ]]; then
            /usr/bin/defaults write "$PREFERENCE_DOMAIN" "$PREFERENCE_KEY" -bool true
        else
            /usr/bin/defaults write "$PREFERENCE_DOMAIN" "$PREFERENCE_KEY" -bool false
        fi
    fi
}
trap cleanup EXIT

if "$REUSE_RUNNING"; then
    /usr/bin/pgrep -x Barline >/dev/null || {
        printf 'error: --reuse-running requires an active Barline process\n' >&2
        exit 1
    }
    if [[ -n "${BARLINE_EVIDENCE_OUTPUT:-}" ]]; then
        source "$ROOT/script/lib/installed-candidate.sh"
        barline_verify_installed_candidate
    fi
else
    /usr/bin/defaults write "$PREFERENCE_DOMAIN" "$PREFERENCE_KEY" -bool true
    if [[ "$PROBE" == status-item-click ]]; then
        if [[ "$BUILD_CONFIGURATION" == Release ]]; then
            BARLINE_APP_BUNDLE_IDENTIFIER="$PREFERENCE_DOMAIN" BARLINE_PRODUCTION_LAUNCH=1 \
                "$ROOT/script/build_and_run.sh" --release --verify
        else
            BARLINE_APP_BUNDLE_IDENTIFIER="$PREFERENCE_DOMAIN" BARLINE_PRODUCTION_LAUNCH=1 \
                "$ROOT/script/build_and_run.sh" --verify
        fi
    elif [[ "$BUILD_CONFIGURATION" == Release ]]; then
        BARLINE_APP_BUNDLE_IDENTIFIER="$PREFERENCE_DOMAIN" BARLINE_RUNTIME_SMOKE=1 \
            "$ROOT/script/build_and_run.sh" --release --verify
    else
        BARLINE_APP_BUNDLE_IDENTIFIER="$PREFERENCE_DOMAIN" BARLINE_RUNTIME_SMOKE=1 \
            "$ROOT/script/build_and_run.sh" --verify
    fi
fi
APP_PID="$(/usr/bin/pgrep -x Barline | /usr/bin/head -1 || true)"
if [[ -n "${BARLINE_EVIDENCE_OUTPUT:-}" ]]; then
    [[ "$APP_PID" == "$BARLINE_EXPECTED_PID" ]] || exit 1
fi
[[ -n "$APP_PID" ]] || {
    printf 'error: Barline process is unavailable for the responsiveness probe\n' >&2
    exit 1
}

# Runtime-smoke uses a DEBUG-only distributed notification. Unlike a status
# item click, that notification is lossy when delivered before the app has
# installed its observer. Bind the probe to the specific freshly launched
# process's ready receipt so PID liveness alone cannot manufacture a false
# cold-launch failure.
if [[ "$PROBE" == "runtime-smoke" ]]; then
    setup_deadline=$((SECONDS + 15))
    setup_ready=false
    while ((SECONDS < setup_deadline)); do
        ready_value="$(/usr/bin/defaults read "$PREFERENCE_DOMAIN" RuntimeSmokeSetupReady 2>/dev/null || true)"
        ready_process_identifier="$(/usr/bin/defaults read "$PREFERENCE_DOMAIN" RuntimeSmokeSetupReadyProcessIdentifier 2>/dev/null || true)"
        if [[ "$ready_value" == "1" && "$ready_process_identifier" == "$APP_PID" ]]; then
            setup_ready=true
            break
        fi
        /bin/sleep 0.1
    done
    if ! "$setup_ready"; then
        printf 'error: Barline did not complete the runtime-smoke setup boundary for process %s\n' "$APP_PID" >&2
        exit 1
    fi
fi
mkdir -p "$MODULE_CACHE"
# Swift permits top-level probe statements in main.swift when compiling the
# shared, independently tested geometry policy alongside the probe.
PERFORMANCE_SOURCE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/barline-performance-source.XXXXXX")"
cp "$ROOT/script/measure-barline-shelf-responsiveness.swift" "$PERFORMANCE_SOURCE_DIR/main.swift"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
    -module-cache-path "$MODULE_CACHE" \
    -framework AppKit -framework CoreGraphics \
    "$ROOT/script/ConcurrentObservation.swift" \
    "$ROOT/script/StatusItemFrameMatching.swift" \
    "$ROOT/script/ShelfProbeCycle.swift" \
    "$PERFORMANCE_SOURCE_DIR/main.swift" -o "$BINARY"
if [[ -n "${BARLINE_EVIDENCE_OUTPUT:-}" ]]; then
    BARLINE_APP_BUNDLE_IDENTIFIER="$PREFERENCE_DOMAIN" \
        BARLINE_EXPECTED_PID="$APP_PID" BARLINE_PERFORMANCE_PROBE="$PROBE" \
        "$BINARY" | tee "$BARLINE_EVIDENCE_OUTPUT.log"
    barline_verify_installed_candidate
    BARLINE_PERFORMANCE_PROBE="$PROBE" ruby "$ROOT/script/write-installed-evidence.rb" \
        --kind performance --log "$BARLINE_EVIDENCE_OUTPUT.log" --output "$BARLINE_EVIDENCE_OUTPUT"
elif [[ -n "$OUTPUT_PATH" ]]; then
    mkdir -p "$(dirname "$OUTPUT_PATH")"
    BARLINE_APP_BUNDLE_IDENTIFIER="$PREFERENCE_DOMAIN" \
        BARLINE_EXPECTED_PID="$APP_PID" BARLINE_PERFORMANCE_PROBE="$PROBE" \
        "$BINARY" | tee -a "$OUTPUT_PATH"
else
    BARLINE_APP_BUNDLE_IDENTIFIER="$PREFERENCE_DOMAIN" \
        BARLINE_EXPECTED_PID="$APP_PID" BARLINE_PERFORMANCE_PROBE="$PROBE" "$BINARY"
fi
