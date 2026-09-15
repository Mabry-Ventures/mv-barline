#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=script/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=script/lib/platform_lane.sh
source "$SCRIPT_DIR/lib/platform_lane.sh"

for version in 27.0 27.0.1 27.1; do
    barline_is_macos27_runtime "$version" || exit 1
done
for version in '' 26.6.2 28.0 270.0 27 27.beta '27.0 unknown'; do
    if barline_is_macos27_runtime "$version"; then
        printf 'Invalid runtime was accepted\n' >&2
        exit 1
    fi
done
for version in 'Xcode 27' 'Xcode 27.1' $'Xcode 27\nBuild version 18A1'; do
    barline_is_xcode27_toolchain "$version" || exit 1
done
for version in '' 'Xcode 26.6' 'Xcode 270' 'Xcode 27invalid' 'Xcode 28'; do
    if barline_is_xcode27_toolchain "$version"; then
        printf 'Invalid toolchain was accepted\n' >&2
        exit 1
    fi
done

test_root="$(mktemp -d "${TMPDIR:-/tmp}/barline-xcode-selection.XXXXXX")"
trap '/bin/rm -f "$test_root/Xcode-Test.app/Contents/Developer/usr/bin/xcodebuild"; /bin/rmdir "$test_root/Xcode-Test.app/Contents/Developer/usr/bin" "$test_root/Xcode-Test.app/Contents/Developer/usr" "$test_root/Xcode-Test.app/Contents/Developer" "$test_root/Xcode-Test.app/Contents" "$test_root/Xcode-Test.app" "$test_root"' EXIT
mkdir -p "$test_root/Xcode-Test.app/Contents/Developer/usr/bin"
touch "$test_root/Xcode-Test.app/Contents/Developer/usr/bin/xcodebuild"
chmod +x "$test_root/Xcode-Test.app/Contents/Developer/usr/bin/xcodebuild"
barline_export_developer_dir "$test_root/Xcode-Test.app"
[[ "$DEVELOPER_DIR" == "$test_root/Xcode-Test.app/Contents/Developer" ]] || exit 1
# The single-quoted command must expand DEVELOPER_DIR inside the child shell.
# shellcheck disable=SC2016
[[ "$(/usr/bin/env sh -c 'printf %s "$DEVELOPER_DIR"')" == "$DEVELOPER_DIR" ]] || {
    printf 'Selected Xcode did not propagate to a child gate\n' >&2
    exit 1
}
printf 'OS lane classification and descendant Xcode selection passed 20 positive/negative cases. No runtime support certified.\n'
