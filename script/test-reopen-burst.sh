#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=script/lib/identity.sh
source "$ROOT/script/lib/identity.sh"

REUSE_RUNNING=false
if [[ "${1:-}" == --reuse-running && $# == 1 ]]; then
    REUSE_RUNNING=true
elif (($#)); then
    printf 'usage: %s [--reuse-running]\n' "$0" >&2
    exit 2
fi
BARLINE_APP_BUNDLE_IDENTIFIER="$(
    barline_resolve_app_bundle_identifier "$ROOT" Release
)"
export BARLINE_APP_BUNDLE_IDENTIFIER
PREFERENCE_KEY="UseBarlineShelf"
ORIGINAL_PREFERENCE="__missing__"

if ! "$REUSE_RUNNING"; then
    if ORIGINAL_PREFERENCE_VALUE="$(/usr/bin/defaults read "$BARLINE_APP_BUNDLE_IDENTIFIER" "$PREFERENCE_KEY" 2>/dev/null)"; then
        ORIGINAL_PREFERENCE="$ORIGINAL_PREFERENCE_VALUE"
    fi
    /usr/bin/defaults write "$BARLINE_APP_BUNDLE_IDENTIFIER" "$PREFERENCE_KEY" -bool true
fi

PROBE=status-item-click
if ! "$REUSE_RUNNING"; then
    # An ad-hoc build does not share a distributed app's TCC identity, so a
    # real hosted status-item click is not a deterministic source gate. Keep
    # the source lane nonactivating and reserve the real click for the signed,
    # notarized installed-candidate lane below.
    export BARLINE_BUILD_CONFIGURATION=Debug
    PROBE=runtime-smoke
else
    export BARLINE_BUILD_CONFIGURATION=Release
fi

cleanup() {
    if ! "$REUSE_RUNNING"; then
        /usr/bin/pkill -x Barline >/dev/null 2>&1 || true
        /usr/bin/pkill -x BarlineMenuService >/dev/null 2>&1 || true
        if [[ "$ORIGINAL_PREFERENCE" == "__missing__" ]]; then
            /usr/bin/defaults delete "$BARLINE_APP_BUNDLE_IDENTIFIER" "$PREFERENCE_KEY" >/dev/null 2>&1 || true
        else
            if [[ "$ORIGINAL_PREFERENCE" == "1" ]]; then
                /usr/bin/defaults write "$BARLINE_APP_BUNDLE_IDENTIFIER" "$PREFERENCE_KEY" -bool true
            else
                /usr/bin/defaults write "$BARLINE_APP_BUNDLE_IDENTIFIER" "$PREFERENCE_KEY" -bool false
            fi
        fi
    fi
}
trap cleanup EXIT

# Keep the historical gate filename but exercise the actual nonactivating shelf
# path. Repeated AppleEvent reopen deliberately raises Settings and violates the
# user's foreground policy. This test does not claim AppleEvent/Settings coverage.
# The signed-candidate installed journey separately proves target interaction.
if ! "$REUSE_RUNNING"; then
    BARLINE_RUNTIME_SMOKE=1 "$ROOT/script/build_and_run.sh" --verify
fi
BARLINE_PERFORMANCE_CYCLES=20 BARLINE_PERFORMANCE_WARMUPS=1 \
    BARLINE_PERFORMANCE_PHASE=baseline \
    BARLINE_EVIDENCE_OUTPUT="${BARLINE_INSTALLED_EVIDENCE_DIR:+$BARLINE_INSTALLED_EVIDENCE_DIR/performance.json}" \
    "$ROOT/script/test-performance-smoke.sh" --reuse-running --probe "$PROBE"

# One forced helper interruption followed by twenty real opens proves same-process
# recovery and makes the p95 latency gate meaningful instead of treating the
# maximum of five noisy samples as a percentile. Sustained
# recovery/soak is a separate lane, explicitly deferred by the user.
BARLINE_EVIDENCE_OUTPUT="${BARLINE_INSTALLED_EVIDENCE_DIR:+$BARLINE_INSTALLED_EVIDENCE_DIR/xpc-interruption.json}" \
    "$ROOT/script/test-xpc-interruption.sh" \
    --reuse-running --recovery-probe "$PROBE"
BARLINE_PERFORMANCE_CYCLES=20 BARLINE_PERFORMANCE_WARMUPS=1 \
    BARLINE_PERFORMANCE_PHASE=post-xpc \
    BARLINE_EVIDENCE_OUTPUT="${BARLINE_INSTALLED_EVIDENCE_DIR:+$BARLINE_INSTALLED_EVIDENCE_DIR/post-xpc-performance.json}" \
    "$ROOT/script/test-performance-smoke.sh" --reuse-running --probe "$PROBE"
printf 'PASS: nonactivating shelf burst and one helper recovery; Settings reopen and soak are separate lanes\n'
