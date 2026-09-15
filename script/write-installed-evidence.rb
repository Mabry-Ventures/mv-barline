#!/usr/bin/env ruby
# frozen_string_literal: true

# The invoking gate verifies the running process and installed candidate binding.
# This writer only translates successfully completed, independently observed gate
# output. It must never be used to turn historical narrative logs into evidence.
require_relative 'validate-installed-evidence'

module InstalledEvidenceWriter
  MAX_LOG_BYTES = 4 * 1024 * 1024
  TARGET_FIELDS = %w[
    physicalEventPath shelfAXTraversalPassed targetInterfaceObserved targetActionObserved
    restorationObserved shelfStayedClosedDuringActivation exactlyOneActivationOpenActionClose
    shelfObserved targetReceiptObserved targetActionUniqueAndOnScreen priorTargetActivations
  ].freeze
  XPC_FIELDS = %w[
    helperTerminatedObserved appProcessPreserved replacementHelperObserved
    recoveryInteractionObserved recoveryProbe
  ].freeze

  def self.check(condition, reason)
    InstalledEvidence.require_check(condition, reason)
  end

  def self.records(path)
    check(File.file?(path) && File.size(path).between?(1, MAX_LOG_BYTES), 'invalid_log_size')
    text = File.read(path, MAX_LOG_BYTES + 1)
    check(text.valid_encoding? && text.bytesize <= MAX_LOG_BYTES, 'invalid_log_encoding_or_size')
    objects = []
    results = []
    text.each_line.with_index do |line, index|
      stripped = line.strip
      if stripped.start_with?('{')
        object = JSON.parse(
          stripped, object_class: InstalledEvidence::UniqueKeys,
          allow_duplicate_key: false, max_nesting: 16
        )
        check(object.is_a?(Hash), 'log_record_not_object')
        %w[verdict interactionVerdict].each do |key|
          check(!object.key?(key) || object[key] == 'PASS', 'failed_log_record')
        end
        if object.key?('originalPointerRestored')
          check(object['originalPointerRestored'].equal?(true), 'pointer_restoration_failed')
        end
        objects << [index, object]
      elsif stripped.start_with?('RESULT ')
        tokens = stripped.split.drop(1)
        values = {}
        tokens.each do |token|
          pair = token.split('=', 2)
          check(pair.length == 2 && !pair.last.empty? && !values.key?(pair.first), 'malformed_result_record')
          values[pair.first] = pair.last
        end
        check(values['verdict'] == 'PASS', 'failed_result_record')
        results << [index, values]
      else
        check(!stripped.match?(/\A(?:ERROR\b|FAIL(?:ED)?\b|error:)/i), 'failed_log_line')
      end
    end
    [objects, results]
  end

  def self.pointer_index(objects, after:)
    pointers = objects.select { |index, object| index > after && object['originalPointerRestored'].equal?(true) }
    check(pointers.length == 1, 'missing_or_duplicate_pointer_restoration')
    pointers.first.first
  end

  def self.performance_result(results, minimum_samples:)
    check(results.length == 1, 'missing_or_duplicate_performance_result')
    index, value = results.first
    check(value['samples']&.match?(/\A[0-9]+\z/), 'invalid_performance_samples')
    samples = value['samples'].to_i
    check(samples.between?(minimum_samples, 1000), 'invalid_performance_samples')
    check(value['timeouts'] == '0', 'performance_timeouts')
    p95 = value['p95_ms']
    check(p95&.match?(/\A[0-9]+(?:\.[0-9]+)?\z/), 'invalid_performance_p95')
    p95 = p95.to_f
    check(p95.finite? && p95.between?(0, 250), 'performance_budget_exceeded')
    check(value['feedback_in_250ms'] == 'true', 'rapid_retry_feedback_failed')
    check(value['silent_cancellation'] == 'false', 'silent_cancellation')
    [index, {
      'probe' => 'status-item-click', 'samples' => samples, 'timeouts' => 0,
      'p95Milliseconds' => p95, 'budgetMilliseconds' => 250,
      'rapidRetryFeedbackInBudget' => true, 'silentCancellation' => false
    }]
  end

  def self.envelope(kind, objects, results, source, executable)
    receipt = {
      'schema' => 1, 'artifactKind' => 'installed-candidate', 'kind' => kind,
      'sourceSHA' => source, 'executableSHA256' => executable, 'verdict' => 'PASS'
    }
    case kind
    when 'target-interface'
      candidates = objects.select { |_, object| object.key?('schema') || object.key?('sourceSHA') }
      check(candidates.length == 1 && results.empty?, 'missing_or_duplicate_target_result')
      index, result = candidates.first
      check(result['schema'].is_a?(Integer) && result['schema'] == 1, 'wrong_target_schema')
      check(result['sourceSHA'] == source, 'target_source_mismatch')
      check(result['executableSHA256'] == executable, 'target_executable_mismatch')
      check(result['verdict'] == 'PASS' && result['interactionVerdict'] == 'PASS', 'target_not_passed')
      lane = ENV['BARLINE_JOURNEY_LANE']
      check(InstalledEvidence::LANES.include?(lane), 'invalid_target_lane')
      target = lane.start_with?('native-') ? 'BF Native' : 'BF Popover'
      button = lane == 'native-right' ? 'right' : 'left'
      check(result['target'] == target && result['button'] == button, 'target_lane_mismatch')
      pointer_index(objects, after: index)
      receipt['lane'] = lane
      receipt['evidence'] = result.select { |key, _| TARGET_FIELDS.include?(key) }
        .merge('originalPointerRestored' => true)
    when 'performance'
      check(ENV['BARLINE_PERFORMANCE_PROBE'] == 'status-item-click', 'wrong_performance_probe')
      index, evidence = performance_result(results, minimum_samples: 20)
      pointer_index(objects, after: index)
      receipt['evidence'] = evidence.merge('originalPointerRestored' => true)
    when 'xpc-interruption'
      index, = performance_result(results, minimum_samples: 1)
      restored_index = pointer_index(objects, after: index)
      completions = objects.select { |_, object| object.key?('helperTerminatedObserved') }
      check(completions.length == 1, 'missing_or_duplicate_xpc_completion')
      completed_index, evidence = completions.first
      check(completed_index > restored_index, 'xpc_completion_precedes_recovery')
      receipt['evidence'] = evidence.select { |key, _| XPC_FIELDS.include?(key) }
        .merge('originalPointerRestored' => true)
    end
    InstalledEvidence.validate_receipt(receipt, source, executable)
    receipt
  end

  def self.write_exclusive(path, receipt)
    created_stat = nil
    begin
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        created_stat = file.stat
        file.write(JSON.generate(receipt) + "\n")
        file.flush
        file.fsync
      end
    rescue SystemCallError, IOError
      if created_stat && File.exist?(path)
        current = File.lstat(path)
        File.unlink(path) if current.dev == created_stat.dev && current.ino == created_stat.ino
      end
      raise
    end
  end

  def self.run(arguments)
    options = {}
    parser = OptionParser.new do |opts|
      opts.on('--kind KIND') { |value| options[:kind] = value }
      opts.on('--log PATH') { |value| options[:log] = value }
      opts.on('--output PATH') { |value| options[:output] = value }
    end
    parser.parse!(arguments)
    check(arguments.empty? && options[:log] && options[:output], 'invalid_arguments')
    check(InstalledEvidence::KINDS.include?(options[:kind]), 'unsupported_evidence_kind')
    source = ENV['BARLINE_SOURCE_SHA']
    executable = ENV['BARLINE_EXECUTABLE_SHA256']
    check(source&.match?(/\A[a-f0-9]{40}\z/), 'invalid_source_environment')
    check(executable&.match?(/\A[a-f0-9]{64}\z/), 'invalid_executable_environment')
    objects, results = records(options[:log])
    receipt = envelope(options[:kind], objects, results, source, executable)
    write_exclusive(options[:output], receipt)
    puts JSON.generate(schema: 1, verdict: 'PASS', receiptWritten: true)
    0
  rescue InstalledEvidence::Invalid => e
    warn JSON.generate(schema: 1, verdict: 'FAIL', reason: e.message)
    1
  rescue JSON::ParserError, JSON::NestingError, EncodingError
    warn JSON.generate(schema: 1, verdict: 'FAIL', reason: 'malformed_log_json')
    1
  rescue OptionParser::ParseError
    warn JSON.generate(schema: 1, verdict: 'FAIL', reason: 'invalid_arguments')
    2
  rescue SystemCallError, IOError
    warn JSON.generate(schema: 1, verdict: 'FAIL', reason: 'receipt_io_error')
    1
  end
end

exit InstalledEvidenceWriter.run(ARGV) if $PROGRAM_NAME == __FILE__
