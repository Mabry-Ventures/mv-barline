#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=script/lib/common.sh
source "$ROOT/script/lib/common.sh"
barline_require_command rg

failures=0
MODULE_CACHE="${TMPDIR:-/tmp}/barline-support-privacy-module-cache"
BINARY="${TMPDIR:-/tmp}/barline-support-privacy-tests"

if ! rg -q '(SupportBundle|DiagnosticBundle)' "$ROOT/Barline" --glob '*.swift'; then
    printf 'error: no Barline support-bundle exporter exists; bundle privacy cannot be runtime-verified\n' >&2
    failures=$((failures + 1))
fi

if ruby -e '
  patterns = /NSHomeDirectory|homeDirectoryForCurrentUser|NSUserName|userName|ProcessInfo\.processInfo\.(arguments|environment)|NSWorkspace\.shared\.runningApplications/
  findings = []
  runtime_patterns = /\\\((?:error(?:\.localizedDescription)?(?:,|\))|(?:\w+\.)?(?:tag|stableID|displayName|title)(?:,|\))|(?:\w+\.)?(?:items|excluded)(?:,|\))|(?:item|app)\.logString)/
  unsafe_examples = [
    %q{logger.error("failed: \(error, privacy: .public)")},
    %q{logger.error("failed: \(error.localizedDescription)")},
    %q{logger.notice("excluded: \(compositeResult.excluded, privacy: .public)")},
    %q{logger.log("item: \(item.stableID, privacy: .public)")},
    %q{logger.log("item: \(item.logString, privacy: .public)")}
  ]
  abort "runtime log privacy scanner self-test failed" unless unsafe_examples.all? { |sample| sample.match?(runtime_patterns) }
  Dir.glob("{Barline,BarlineMenuService}/**/*.swift").each do |path|
    lines = File.readlines(path)
    lines.each_with_index do |line, index|
      next unless line.match?(/logger\.(log|debug|info|notice|warning|error|fault)|Logger\.[A-Za-z]+\.(log|debug|info|notice|warning|error|fault)/)
      statement = ""
      balance = 0
      lines[index, 12].each do |part|
        statement << part
        balance += part.count("(") - part.count(")")
        break if balance <= 0
      end
      findings << "#{path}:#{index + 1}" if statement.match?(patterns) || statement.match?(runtime_patterns)
    end
  end
  if findings.any?
    warn "unsanitized metadata or error is reachable from a runtime logging statement: #{findings.join(", ")}"
    exit 1
  end
'; then
    :
else
    failures=$((failures + 1))
fi

if git -C "$ROOT" grep -n -E -- '-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----|AKIA[0-9A-Z]{16}'; then
    printf 'error: credential-like content is tracked and could leak into diagnostics\n' >&2
    failures=$((failures + 1))
fi

if rg -q 'failureDescription = String\(describing: error\)' "$ROOT/Barline"; then
    printf 'error: reopen recovery persists an unsanitized error description\n' >&2
    failures=$((failures + 1))
fi

if ((failures == 0)); then
    swift build --package-path "$ROOT/BarlineCore"
    BIN_PATH="$(swift build --package-path "$ROOT/BarlineCore" --show-bin-path)"
    if ! barline_resolve_core_build_products "$BIN_PATH"; then
        failures=$((failures + 1))
    else
        mkdir -p "$MODULE_CACHE"
        if ! xcrun swiftc \
            -module-cache-path "$MODULE_CACHE" \
            -I "$BARLINE_CORE_MODULE_PATH" \
            "$ROOT/Barline/Platform/Diagnostics/SupportBundleExporter.swift" \
            "$ROOT/script/test-support-bundle-privacy.swift" \
            "${BARLINE_CORE_OBJECTS[@]}" \
            -o "$BINARY"; then
            failures=$((failures + 1))
        elif ! "$BINARY"; then
            failures=$((failures + 1))
        fi
    fi
fi

if ((failures)); then
    printf 'support-bundle privacy gate failed with %d finding(s)\n' "$failures" >&2
    exit 1
fi

printf 'PASS: support-bundle exporter exists and logging/source credential privacy checks passed\n'
