#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Synthetic fixtures test only the validator. They are deliberately ephemeral,
# never retained in a candidate's actual qualification receipt directory.
ruby - "$ROOT/script/validate-installed-evidence.rb" <<'RUBY'
require 'json'
require 'tmpdir'
require 'open3'
validator = ARGV.fetch(0)
source = 'a' * 40
executable = 'b' * 64
base = {
  'schema' => 1, 'artifactKind' => 'installed-candidate', 'verdict' => 'PASS',
  'sourceSHA' => source, 'executableSHA256' => executable
}
target = %w[physicalEventPath shelfAXTraversalPassed targetInterfaceObserved targetActionObserved
            restorationObserved shelfStayedClosedDuringActivation exactlyOneActivationOpenActionClose
            originalPointerRestored shelfObserved targetReceiptObserved
            targetActionUniqueAndOnScreen].to_h { |field| [field, true] }
fixtures = %w[native-left native-right popover-left popover-reuse].map do |lane|
  evidence = lane == 'popover-reuse' ? target.merge('priorTargetActivations' => 1) : target
  base.merge('kind' => 'target-interface', 'lane' => lane, 'evidence' => evidence)
end
fixtures << base.merge('kind' => 'xpc-interruption', 'evidence' => {
  'recoveryProbe' => 'status-item-click', 'helperTerminatedObserved' => true,
  'appProcessPreserved' => true, 'replacementHelperObserved' => true,
  'recoveryInteractionObserved' => true, 'originalPointerRestored' => true
})
performance = base.merge('kind' => 'performance', 'phase' => 'baseline', 'evidence' => {
  'probe' => 'status-item-click', 'samples' => 20, 'timeouts' => 0,
  'p95Milliseconds' => 250, 'maxMilliseconds' => 265, 'budgetMilliseconds' => 250,
  'rapidRetryFeedbackInBudget' => true, 'silentCancellation' => false,
  'originalPointerRestored' => true
})
fixtures << performance
fixtures << performance.merge('phase' => 'post-xpc')
count = 0
check = lambda do |label, expected, mutation = nil, raw: nil, args: []|
  Dir.mktmpdir('barline-validator-tests-') do |directory|
    values = Marshal.load(Marshal.dump(fixtures))
    mutation&.call(values)
    values.each_with_index { |value, i| File.write(File.join(directory, "#{i}.json"), JSON.generate(value)) }
    File.write(File.join(directory, '0.json'), raw) if raw
    stdout, stderr, status = Open3.capture3('ruby', validator, '--source-sha', source,
      '--executable-sha256', executable, '--evidence-dir', directory, *args)
    raise "#{label}: incorrect exit status" unless status.success? == expected
    result = JSON.parse(expected ? stdout : stderr)
    raise "#{label}: incorrect verdict" unless result['verdict'] == (expected ? 'PASS' : 'FAIL')
    raise "#{label}: leaked payload" if stdout.include?(directory) || stderr.include?(directory)
    count += 1
  end
end
check.call('complete candidate', true)
check.call('missing all', false, ->(v) { v.clear })
fixtures.length.times { |i| check.call("missing receipt #{i}", false, ->(v) { v.delete_at(i) }) }
check.call('wrong source', false, ->(v) { v[0]['sourceSHA'] = 'c' * 40 })
check.call('wrong executable', false, ->(v) { v[4]['executableSHA256'] = 'c' * 64 })
check.call('missing identity', false, ->(v) { v[1].delete('sourceSHA') })
check.call('wrong artifact', false, ->(v) { v[0]['artifactKind'] = 'debug-build' })
check.call('wrong kind', false, ->(v) { v[0]['kind'] = 'fixture' })
check.call('unknown lane', false, ->(v) { v[0]['lane'] = 'native-middle' })
check.call('reuse without prior activation', false, ->(v) { v[3]['evidence'].delete('priorTargetActivations') })
[0, -1, '1', 1.0, true].each do |value|
  check.call('invalid reuse prior activations', false, ->(v) { v[3]['evidence']['priorTargetActivations'] = value })
end
check.call('non-reuse zero prior activations', true, ->(v) { v[0]['evidence']['priorTargetActivations'] = 0 })
check.call('non-reuse invalid prior activations', false, ->(v) { v[0]['evidence']['priorTargetActivations'] = -1 })
check.call('duplicate receipt', false, ->(v) { v << v[0] })
check.call('duplicate failed receipt', false, ->(v) { v << v[0].merge('verdict' => 'FAIL') })
check.call('observed only', false, ->(v) { v[5]['verdict'] = 'OBSERVED' })
check.call('unsupported schema', false, ->(v) { v[0]['schema'] = 2 })
check.call('floating schema', false, ->(v) { v[0]['schema'] = 1.0 })
check.call('missing evidence', false, ->(v) { v[0].delete('evidence') })
target.each_key do |field|
  check.call("unproven #{field}", false, ->(v) { v[0]['evidence'][field] = false })
  check.call("string boolean #{field}", false, ->(v) { v[0]['evidence'][field] = 'true' })
end
fixtures[4]['evidence'].each_key do |field|
  check.call("missing xpc #{field}", false, ->(v) { v[4]['evidence'].delete(field) })
end
check.call('Settings recovery', false, ->(v) { v[4]['evidence']['recoveryProbe'] = 'apple-event-reopen' })
check.call('debug performance', false, ->(v) { v[5]['evidence']['probe'] = 'runtime-smoke' })
check.call('missing performance phase', false, ->(v) { v[5].delete('phase') })
check.call('duplicate performance phase', false, ->(v) { v[6]['phase'] = 'baseline' })
{ 'samples' => [0, 19, 1001, 20.0, '20', true], 'timeouts' => [1, -1, 0.0, '0'],
  'p95Milliseconds' => [-1, 250.01, '25', nil, true],
  'maxMilliseconds' => [249, -1, '265', nil],
  'budgetMilliseconds' => [0, -1, 251, '250', nil] }.each do |field, values|
  values.each do |value|
    check.call("invalid performance #{field}", false, ->(v) { v[5]['evidence'][field] = value })
  end
end
check.call('rapid retry failed', false, ->(v) { v[5]['evidence']['rapidRetryFeedbackInBudget'] = false })
check.call('silent cancellation', false, ->(v) { v[5]['evidence']['silentCancellation'] = true })
check.call('string false', false, ->(v) { v[5]['evidence']['silentCancellation'] = 'false' })
check.call('pointer not restored', false, ->(v) { v[5]['evidence']['originalPointerRestored'] = false })
check.call('extra lane', false, ->(v) { v[5]['lane'] = 'native-left' })
check.call('malformed JSON', false, raw: '{')
check.call('array instead of object', false, raw: '[]')
check.call('NaN', false, raw: JSON.generate(fixtures[5]).sub('250', 'NaN'))
check.call('Infinity', false, raw: JSON.generate(fixtures[5]).sub('250', 'Infinity'))
check.call('overflow number', false, raw: JSON.generate(fixtures[5]).sub('250', '1e9999'))
check.call('duplicate JSON key', false, raw: JSON.generate(fixtures[0]).sub('"schema":1', '"schema":0,"schema":1'))
check.call('oversized receipt', false, raw: ' ' * 131_073)
check.call('invalid CLI identity', false, nil, args: ['--source-sha', 'invalid'])
puts "PASS: #{count} deterministic installed evidence validator cases (synthetic fixtures only)"
RUBY
