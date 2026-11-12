# frozen_string_literal: true

# Only the audit executable and canonical parent `bin/rails test` preload collect data.
audit_root = File.expand_path('..', __dir__)
return unless (File.identical?($PROGRAM_NAME, File.join(audit_root, 'bin/test-audit')) && ARGV.first != '--compare') ||
              (File.identical?($PROGRAM_NAME, File.join(audit_root, 'bin/rails')) && ARGV.first == 'test')

require_relative '../config/boot'
require 'json'
require 'fileutils'
require 'coverage'
Coverage.start(lines: true, branches: true)
require 'minitest/autorun'

module TestSuiteAudit
  ROOT = File.expand_path('..', __dir__)
  @rows = []
  PARENT_PID = Process.pid
  @reload_hits = {}

  class << self
    attr_reader :rows, :reload_hits
  end

  def self.parent_process?
    Process.pid == PARENT_PID
  end

  # Counters are maxima per native identity, not aggregate execution totals.
  def self.merge_hits!(target, incoming)
    lines = incoming.fetch(:lines)
    target[:lines].concat(Array.new(lines.length - target[:lines].length)) if lines.length > target[:lines].length
    lines.each_with_index do |hits, index|
      next if hits.nil?

      target[:lines][index] = [target[:lines][index].to_i, hits].max
    end
    incoming.fetch(:branches).each do |condition, arms|
      retained = target[:branches][condition] ||= {}
      arms.each { |arm, hits| retained[arm] = [retained[arm].to_i, hits].max }
    end
    target
  end

  def self.load_candidates(argument)
    filename = case argument
               when String
                 argument
               else
                 if defined?(Pathname)
                   case argument
                   when Pathname
                     argument.to_s
                   end
                 end
               end
    # Unknown path-like objects are left to native coercion; retain current target hits conservatively.
    return nil unless filename
    return [] unless filename.encoding.ascii_compatible?
    return [] if filename.include?("\0")

    candidates = [File.expand_path(filename)]
    candidates.concat($LOAD_PATH.map { |directory| File.expand_path(filename, directory) }) unless filename.start_with?('/', './', '../')
    candidates.select { |path| path.start_with?("#{ROOT}/app/", "#{ROOT}/lib/") }
  rescue ArgumentError, TypeError
    [] # Native load owns invalid path arguments and their error messages.
  end

  def self.before_load(arguments)
    return unless parent_process? && Coverage.running? && arguments.length.between?(1, 2)

    candidates = load_candidates(arguments.first)
    return if candidates == []

    Coverage.peek_result.each do |path, data|
      next unless path.start_with?("#{ROOT}/app/", "#{ROOT}/lib/")
      next unless candidates.nil? || candidates.include?(path)

      merge_hits!(@reload_hits[path] ||= { lines: [], branches: {} }, data)
    end
  end

  def self.install_reload_retention
    # Both entrypoints retain native load's argument/wrap/result/error behavior.
    [Kernel, Kernel.singleton_class].each do |owner|
      wrapper = Module.new do
        define_method(:load) do |*arguments, **options, &block|
          TestSuiteAudit.before_load(arguments)
          super(*arguments, **options, &block)
        end
      end
      wrapper.send(:private, :load) if owner == Kernel
      owner.prepend(wrapper)
    end
  end

  def self.final_coverage
    native = Coverage.result.dup
    return native unless parent_process?

    @reload_hits.each do |path, retained|
      native[path] = merge_hits!({ lines: [], branches: {} }, native.fetch(path, retained))
      merge_hits!(native[path], retained)
    end
    native
  end

  module Timing
    def run
      source = method(name).source_location
      result = super
      TestSuiteAudit.rows << {
        test: "#{self.class}##{name}",
        file: source&.first&.delete_prefix("#{TestSuiteAudit::ROOT}/"),
        assertions: result.assertions,
        seconds: result.time,
        failures: result.failures.map { |failure| failure.class.name },
        skipped: result.skipped?
      }
      result
    end
  end
end

TestSuiteAudit.install_reload_retention
Minitest::Test.prepend(TestSuiteAudit::Timing)
Minitest.after_run do
  next unless TestSuiteAudit.parent_process?

  root = TestSuiteAudit::ROOT
  coverage = TestSuiteAudit.final_coverage.filter_map do |path, data|
    relative = path.delete_prefix("#{root}/")
    next unless path.start_with?("#{root}/") && relative.start_with?('app/', 'lib/')

    branches = data.fetch(:branches).flat_map do |condition, arms|
      arms.map { |arm, hits| [condition, arm, hits] }
    end
    [relative, { lines: data.fetch(:lines), branches: branches }]
  end.to_h
  rows = TestSuiteAudit.rows
  report = {
    measurement: {
      coverage_mode: 'parent_process_reload_hit_union',
      counters: 'maximum_per_native_identity_not_aggregate_execution_totals',
      reload_snapshot_paths: TestSuiteAudit.reload_hits.keys.map { |path| path.delete_prefix("#{root}/") }.sort
    },
    summary: {
      tests: rows.length,
      assertions: rows.sum { |row| row.fetch(:assertions) },
      test_seconds: rows.sum { |row| row.fetch(:seconds) },
      failed_tests: rows.count { |row| (row.fetch(:failures) - ['Minitest::Skip']).any? },
      skipped_tests: rows.count { |row| row.fetch(:skipped) },
      covered_lines: coverage.values.sum { |data| data.fetch(:lines).count { |hits| hits.to_i.positive? } },
      covered_branches: coverage.values.sum { |data| data.fetch(:branches).count { |branch| branch.last.positive? } }
    },
    tests: rows.sort_by { |row| -row.fetch(:seconds) },
    coverage: coverage,
    unloaded_files: Dir.glob('{app,lib}/**/*.rb').sort - coverage.keys
  }
  output = ENV.fetch('TEST_AUDIT_OUTPUT', 'tmp/test-audit.json')
  FileUtils.mkdir_p(File.dirname(output))
  File.write(output, JSON.pretty_generate(report))
  warn "Test audit: #{output} (#{report.fetch(:summary).inspect})"
end
