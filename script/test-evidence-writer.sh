#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ruby - "$ROOT/script/write-installed-evidence.rb" <<'RUBY'
require 'json'
require 'tmpdir'
require 'open3'
writer = ARGV.fetch(0)
source = 'a' * 40
executable = 'b' * 64
environment = {
  'BARLINE_SOURCE_SHA' => source, 'BARLINE_EXECUTABLE_SHA256' => executable,
  'BARLINE_JOURNEY_LANE' => 'native-left', 'BARLINE_PERFORMANCE_PROBE' => 'status-item-click',
  'BARLINE_PERFORMANCE_PHASE' => 'baseline'
}
target = {
  'schema' => 1, 'sourceSHA' => source, 'executableSHA256' => executable,
  'verdict' => 'PASS', 'interactionVerdict' => 'PASS', 'target' => 'BF Native', 'button' => 'left',
  'priorTargetActivations' => 1
}
%w[physicalEventPath shelfAXTraversalPassed targetInterfaceObserved targetActionObserved
   restorationObserved shelfStayedClosedDuringActivation exactlyOneActivationOpenActionClose
   shelfObserved targetReceiptObserved targetActionUniqueAndOnScreen].each { |key| target[key] = true }
pointer = JSON.generate('originalPointerRestored' => true)
target_log = JSON.generate(target) + "\n#{pointer}\n"
performance_result = 'RESULT samples=20 timeouts=0 median_ms=25.0 p95_ms=42.5 max_ms=65.0 feedback_in_250ms=true silent_cancellation=false verdict=PASS'
performance_log = performance_result + "\n#{pointer}\n"
xpc = {
  'helperTerminatedObserved' => true, 'appProcessPreserved' => true,
  'replacementHelperObserved' => true, 'recoveryInteractionObserved' => true,
  'recoveryProbe' => 'status-item-click'
}
xpc_log = performance_log.sub('samples=20', 'samples=1') + JSON.generate(xpc) + "\n"
count = 0
check = lambda do |label, kind, log, passes, env: {}, existing: false|
  Dir.mktmpdir('barline-evidence-writer-tests-') do |directory|
    input = File.join(directory, 'input.log')
    output = File.join(directory, 'output.json')
    File.write(input, log)
    File.write(output, 'existing evidence must survive') if existing
    stdout, stderr, status = Open3.capture3(environment.merge(env), 'ruby', writer,
      '--kind', kind, '--log', input, '--output', output)
    raise "#{label}: exit mismatch" unless status.success? == passes
    raise "#{label}: payload leak" if (stdout + stderr).include?(directory)
    if passes
      receipt = JSON.parse(File.read(output))
      raise "#{label}: bad envelope" unless receipt['verdict'] == 'PASS' && receipt['kind'] == kind
      raise "#{label}: bad identity" unless receipt['sourceSHA'] == source && receipt['executableSHA256'] == executable
    elsif existing
      raise "#{label}: overwrite" unless File.read(output) == 'existing evidence must survive'
    else
      raise "#{label}: false pass artifact" if File.exist?(output)
    end
    count += 1
  end
end
check.call('target valid', 'target-interface', target_log, true)
check.call('performance valid', 'performance', performance_log, true)
check.call('post-XPC performance valid', 'performance', performance_log, true,
  env: { 'BARLINE_PERFORMANCE_PHASE' => 'post-xpc' })
check.call('invalid performance phase', 'performance', performance_log, false,
  env: { 'BARLINE_PERFORMANCE_PHASE' => 'unknown' })
check.call('one-sample XPC valid', 'xpc-interruption', xpc_log, true)
check.call('right target valid', 'target-interface', target_log.sub('"button":"left"', '"button":"right"'), true,
  env: { 'BARLINE_JOURNEY_LANE' => 'native-right' })
%w[popover-left popover-reuse].each do |lane|
  check.call(lane, 'target-interface', target_log.sub('BF Native', 'BF Popover'), true,
    env: { 'BARLINE_JOURNEY_LANE' => lane })
end
check.call('reuse no prior activation', 'target-interface', target_log.sub('BF Native', 'BF Popover')
  .sub('"priorTargetActivations":1', '"priorTargetActivations":0'), false,
  env: { 'BARLINE_JOURNEY_LANE' => 'popover-reuse' })
check.call('reuse missing prior activation', 'target-interface', target_log.sub('BF Native', 'BF Popover')
  .sub(',"priorTargetActivations":1', ''), false,
  env: { 'BARLINE_JOURNEY_LANE' => 'popover-reuse' })
check.call('reuse string prior activation', 'target-interface', target_log.sub('BF Native', 'BF Popover')
  .sub('"priorTargetActivations":1', '"priorTargetActivations":"1"'), false,
  env: { 'BARLINE_JOURNEY_LANE' => 'popover-reuse' })
check.call('wrong lane', 'target-interface', target_log, false, env: { 'BARLINE_JOURNEY_LANE' => 'native-right' })
check.call('source mismatch', 'target-interface', target_log.sub(source, 'c' * 40), false)
check.call('executable mismatch', 'target-interface', target_log.sub(executable, 'c' * 64), false)
check.call('invalid source env', 'target-interface', target_log, false, env: { 'BARLINE_SOURCE_SHA' => '' })
check.call('missing executable env', 'performance', performance_log, false, env: { 'BARLINE_EXECUTABLE_SHA256' => nil })
check.call('bad JSON', 'target-interface', "{garbled\n" + target_log, false)
check.call('duplicate JSON keys', 'target-interface', target_log.sub('"schema":1', '"schema":0,"schema":1'), false)
check.call('missing pointer', 'target-interface', JSON.generate(target), false)
check.call('pointer before completion', 'target-interface', "#{pointer}\n" + JSON.generate(target), false)
check.call('pointer false', 'target-interface', target_log.sub(pointer, '{"originalPointerRestored":false}'), false)
check.call('failed prior record', 'target-interface', "{\"verdict\":\"FAIL\"}\n" + target_log, false)
check.call('failed line', 'target-interface', "ERROR failed\n" + target_log, false)
check.call('target proof false', 'target-interface', target_log.sub('"restorationObserved":true', '"restorationObserved":false'), false)
check.call('target proof string', 'target-interface', target_log.sub('"shelfAXTraversalPassed":true', '"shelfAXTraversalPassed":"true"'), false)
check.call('duplicate result', 'target-interface', target_log + target_log, false)
check.call('existing receipt', 'target-interface', target_log, false, existing: true)
check.call('performance missing pointer', 'performance', performance_result, false)
check.call('performance wrong probe', 'performance', performance_log, false, env: { 'BARLINE_PERFORMANCE_PROBE' => 'runtime-smoke' })
check.call('performance invalid maximum', 'performance', performance_log.sub('max_ms=65.0', 'max_ms=40.0'), false)
%w[samples=19 timeouts=1 p95_ms=251.0 p95_ms=NaN feedback_in_250ms=false silent_cancellation=true verdict=FAIL verdict=OBSERVED].each do |replacement|
  key = replacement.split('=').first
  check.call(replacement, 'performance', performance_log.sub(/#{key}=[^\s]+/, replacement), false)
end
check.call('duplicate performance token', 'performance', performance_log.sub('samples=20', 'samples=20 samples=20'), false)
check.call('duplicate performance results', 'performance', performance_log + performance_log, false)
check.call('XPC missing recovery', 'xpc-interruption', JSON.generate(xpc), false)
check.call('XPC zero recovery samples', 'xpc-interruption', xpc_log.sub('samples=1', 'samples=0'), false)
check.call('XPC recovery failed', 'xpc-interruption', xpc_log.sub('verdict=PASS', 'verdict=FAIL'), false)
check.call('XPC recovery timeout', 'xpc-interruption', xpc_log.sub('timeouts=0', 'timeouts=1'), false)
check.call('XPC proof false', 'xpc-interruption', xpc_log.sub('"replacementHelperObserved":true', '"replacementHelperObserved":false'), false)
check.call('XPC Settings probe', 'xpc-interruption', xpc_log.sub('status-item-click', 'apple-event-reopen'), false)
check.call('XPC premature completion', 'xpc-interruption', JSON.generate(xpc) + "\n" + performance_log, false)
puts "PASS: #{count} deterministic installed evidence writer cases (synthetic fixtures only)"
RUBY
