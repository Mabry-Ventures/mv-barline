#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/barline-capture-submission.XXXXXX")"
trap '/bin/rm -f "$TASK_DIR/probe"; /bin/rmdir "$TASK_DIR"' EXIT
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
    "$ROOT/Barline/Utilities/ProfileCaptureSubmission.swift" \
    "$ROOT/script/tests/ProfileCaptureSubmissionProbe.swift" -o "$TASK_DIR/probe"
"$TASK_DIR/probe"
