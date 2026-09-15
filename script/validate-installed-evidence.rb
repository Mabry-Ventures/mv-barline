#!/usr/bin/env ruby
# frozen_string_literal: true

# Validate a dedicated directory of installed-candidate qualification receipts.
# Receipts must be written by gates only after their observed checks succeed;
# this validator verifies their contract and candidate binding, not authenticity.
# No raw logs, fixture receipts, build metadata, or historical retries belong here.
require 'json'
require 'optparse'

module InstalledEvidence
  LANES = %w[native-left native-right popover-left popover-reuse].freeze
  KINDS = %w[target-interface xpc-interruption performance].freeze
  MAX_BYTES = 131_072
  MAX_RECEIPTS = 32

  class Invalid < StandardError; end

  class UniqueKeys < Hash
    def []=(key, value)
      raise Invalid, 'duplicate_json_key' if key?(key)

      super
    end
  end

  def self.require_check(condition, reason)
    raise Invalid, reason unless condition
  end

  def self.true_fields(evidence, fields, kind)
    fields.each { |field| require_check(evidence[field].equal?(true), "#{kind}_#{field}_not_proven") }
  end

  def self.finite_number?(value)
    value.is_a?(Numeric) && value.finite?
  end

  def self.validate_receipt(receipt, source_sha, executable_sha)
    require_check(receipt.is_a?(Hash), 'receipt_not_object')
    require_check(receipt['schema'].is_a?(Integer) && receipt['schema'] == 1, 'unsupported_schema')
    require_check(receipt['artifactKind'] == 'installed-candidate', 'wrong_artifact_kind')
    kind = receipt['kind']
    require_check(KINDS.include?(kind), 'unsupported_evidence_kind')
    require_check(receipt['verdict'] == 'PASS', 'receipt_not_passed')
    require_check(receipt['sourceSHA'] == source_sha, 'source_sha_mismatch')
    require_check(receipt['executableSHA256'] == executable_sha, 'executable_sha256_mismatch')
    evidence = receipt['evidence']
    require_check(evidence.is_a?(Hash), 'missing_evidence_object')

    case kind
    when 'target-interface'
      lane = receipt['lane']
      require_check(LANES.include?(lane), 'unsupported_target_lane')
      prior_activations = evidence['priorTargetActivations']
      if lane == 'popover-reuse' || evidence.key?('priorTargetActivations')
        minimum = lane == 'popover-reuse' ? 1 : 0
        require_check(prior_activations.is_a?(Integer) && prior_activations >= minimum,
                      'target_prior_activations_not_proven')
      end
      true_fields(evidence, %w[
        physicalEventPath shelfAXTraversalPassed targetInterfaceObserved
        targetActionObserved restorationObserved shelfStayedClosedDuringActivation
        exactlyOneActivationOpenActionClose originalPointerRestored
        shelfObserved targetReceiptObserved targetActionUniqueAndOnScreen
      ], kind)
      [kind, lane]
    when 'xpc-interruption'
      require_check(!receipt.key?('lane'), 'unexpected_lane')
      require_check(evidence['recoveryProbe'] == 'status-item-click', 'xpc_wrong_recovery_probe')
      true_fields(evidence, %w[
        helperTerminatedObserved appProcessPreserved replacementHelperObserved
        recoveryInteractionObserved originalPointerRestored
      ], kind)
      [kind]
    when 'performance'
      require_check(!receipt.key?('lane'), 'unexpected_lane')
      require_check(evidence['probe'] == 'status-item-click', 'performance_wrong_probe')
      samples = evidence['samples']
      require_check(samples.is_a?(Integer) && samples.between?(20, 1000), 'performance_invalid_sample_count')
      require_check(evidence['timeouts'].is_a?(Integer) && evidence['timeouts'].zero?, 'performance_timeouts')
      p95 = evidence['p95Milliseconds']
      budget = evidence['budgetMilliseconds']
      require_check(finite_number?(budget) && budget.positive? && budget <= 250, 'performance_invalid_budget')
      require_check(finite_number?(p95) && p95 >= 0 && p95 <= budget, 'performance_budget_exceeded')
      true_fields(evidence, %w[rapidRetryFeedbackInBudget originalPointerRestored], kind)
      require_check(evidence['silentCancellation'].equal?(false), 'performance_silent_cancellation')
      [kind]
    end
  end

  def self.run(arguments)
    options = {}
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: validate-installed-evidence.rb --source-sha SHA --executable-sha256 SHA --evidence-dir DIR'
      opts.on('--source-sha SHA') { |value| options[:source] = value }
      opts.on('--executable-sha256 SHA') { |value| options[:executable] = value }
      opts.on('--evidence-dir DIR') { |value| options[:directory] = value }
    end
    parser.parse!(arguments)
    require_check(arguments.empty?, 'unexpected_arguments')
    require_check(options[:source]&.match?(/\A[a-f0-9]{40}\z/), 'invalid_expected_source_sha')
    require_check(options[:executable]&.match?(/\A[a-f0-9]{64}\z/), 'invalid_expected_executable_sha256')
    directory = options[:directory]
    require_check(directory && File.directory?(directory), 'evidence_directory_missing')
    # A dedicated, flat directory prevents accidentally treating metadata or a
    # fixture's counters as release evidence. Any JSON present must validate.
    files = Dir.children(directory).select { |name| name.end_with?('.json') }.sort
    require_check(files.length.between?(1, MAX_RECEIPTS), 'missing_or_excessive_receipts')
    seen = {}
    files.each do |name|
      path = File.join(directory, name)
      require_check(File.file?(path) && !File.symlink?(path), 'receipt_not_regular_file')
      require_check(File.size(path).between?(2, MAX_BYTES), 'invalid_receipt_size')
      receipt = JSON.parse(
        File.read(path, MAX_BYTES + 1), object_class: UniqueKeys,
        allow_duplicate_key: false, max_nesting: 16
      )
      key = validate_receipt(receipt, options[:source], options[:executable])
      require_check(!seen.key?(key), 'duplicate_evidence_receipt')
      seen[key] = true
    end
    LANES.each { |lane| require_check(seen[['target-interface', lane]], "missing_target_lane_#{lane}") }
    %w[xpc-interruption performance].each { |kind| require_check(seen[[kind]], "missing_#{kind}") }
    puts JSON.generate(schema: 1, verdict: 'PASS', artifactKind: 'installed-candidate', validatedReceipts: seen.length)
    0
  rescue Invalid => e
    warn JSON.generate(schema: 1, verdict: 'FAIL', reason: e.message)
    1
  rescue JSON::ParserError, JSON::NestingError, EncodingError
    warn JSON.generate(schema: 1, verdict: 'FAIL', reason: 'malformed_receipt_json')
    1
  rescue OptionParser::ParseError
    warn JSON.generate(schema: 1, verdict: 'FAIL', reason: 'invalid_arguments')
    2
  rescue SystemCallError, IOError
    # Never echo receipt data, user paths, or exception text into CI logs.
    warn JSON.generate(schema: 1, verdict: 'FAIL', reason: 'evidence_io_error')
    1
  end
end

exit InstalledEvidence.run(ARGV) if $PROGRAM_NAME == __FILE__
