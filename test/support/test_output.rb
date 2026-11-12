# frozen_string_literal: true

require 'fileutils'
require 'logger'
require 'active_support'
require 'active_support/logger'
require 'active_support/broadcast_logger'

# Keeps complete Rails logs while reporting unclassified error paths concisely.
module TestOutput
  class << self
    attr_reader :log_path

    def verbose?
      %w[1 true].include?(ENV.fetch('VERBOSE_TESTS', '').downcase)
    end

    def configure(root:, output: $stderr)
      @root = File.expand_path(root.to_s)
      @output = output
      @pid = Process.pid
      @mutex = Mutex.new
      @groups = {}
      @current = nil
      @reported = false
      @started = false
      @console_failed = false
      @log_path = File.join(@root, 'log/test.log')
      FileUtils.mkdir_p(File.dirname(@log_path))
      @file_logger = ActiveSupport::Logger.new(@log_path)
      formatter = Logger::Formatter.new
      @file_logger.formatter = lambda do |severity, time, progname, message|
        formatted = formatter.call(severity, time, progname, message)
        "[observed while #{collect(severity, message)}] #{formatted}"
      end
      @file_logger.level = verbose? ? Logger::DEBUG : Logger::WARN
      return @file_logger unless verbose?

      console = ActiveSupport::Logger.new($stdout)
      console.formatter = Logger::Formatter.new
      console.level = Logger::DEBUG
      ActiveSupport::BroadcastLogger.new(@file_logger, console)
    end

    def install
      return if @installed

      Minitest::Test.prepend(Lifecycle)
      Minitest.after_run { TestOutput.report }
      @installed = true
    end

    def reset_after_fork
      return if @pid == Process.pid

      @pid = Process.pid
      @mutex = Mutex.new
      @groups = {}
      @current = nil
      @reported = false
      @started = false
      @console_failed = false
      @log_path = File.join(@root, "log/test-#{@pid}.log")
      @file_logger.reopen(@log_path)
    end

    def start_test(name)
      @mutex.synchronize do
        @started = true
        @current = { name: name, offset: File.size(@log_path), groups: {} }
      end
    rescue StandardError => e
      emit "Test log tracking unavailable: #{e.class}; full log: #{@log_path}"
    end

    def finish_test(result)
      failed = !result || result.failures.any? { |failure| !failure.is_a?(Minitest::Skip) }
      current = @mutex.synchronize do
        value = @current
        @current = nil
        merge_groups(value[:groups], value[:name]) if value && !failed
        value
      end
      return unless current && failed

      if result&.skipped?
        messages = result.failures.grep_v(Minitest::Skip).map(&:message).join("\n")
        emit "Failures following skip in #{current[:name]}:\n#{messages.lines.first(40).join[0, 8192]}"
      end
      emit "\nRecent process log context for #{current[:name]} (#{@log_path}):"
      size = File.size(@log_path)
      start = [current[:offset], size - 32_768].max
      text = File.open(@log_path, 'r') do |file|
        file.seek(start)
        file.read
      end
      emit text.lines.last(40).join
      emit "Full test log: #{@log_path}"
    rescue StandardError => e
      emit "Test log context unavailable: #{e.class}; full log: #{@log_path}"
    end

    def report
      groups = @mutex.synchronize do
        return if @reported

        @reported = true
        @groups.transform_values { |group| group.merge(tests: group[:tests].dup) }
      end
      lines = ["\nTest log (PID #{Process.pid}): #{@log_path}"]
      unless groups.empty?
        total = groups.values.sum { |group| group[:count] }
        lines << "Unclassified ERROR/FATAL logs: #{total} events at #{groups.length} sources; passing tests do not establish these are expected."
        groups.sort_by { |key, _| key }.each do |(severity, source), group|
          names = group[:tests].first(2)
          names << "(+#{group[:tests].length - 2} more)" if group[:tests].length > 2
          lines << "  #{severity} #{source}: #{group[:count]} events; observed: #{names.join(', ')}"
          lines << "    #{group[:sample]}"
        end
        lines << "Full messages/backtraces: #{@log_path}"
      end
      emit lines.join("\n")
    rescue StandardError => e
      emit "Test error-log summary unavailable: #{e.class}; full log: #{@log_path}"
    end

    private

    def emit(message)
      return if @mutex.synchronize { @console_failed }

      @output.puts message
    rescue StandardError => e
      begin
        notify = @mutex.synchronize do
          first = !@console_failed
          @console_failed = true
          first
        end
        warn "Test output console unavailable: #{e.class}; full log: #{@log_path}" if notify
      rescue StandardError
        # A broken diagnostic stream must not replace the original test result.
        nil
      end
    end

    def collect(severity, message)
      error = %w[ERROR FATAL].include?(severity)
      if error
        locations = caller_locations
        location = locations.find { |entry| entry.path.start_with?("#{@root}/app/", "#{@root}/lib/") }
        location ||= locations.find { |entry| entry.path.start_with?("#{@root}/config/") }
        location ||= locations.find { |entry| entry.path.start_with?("#{@root}/test/") && entry.path != __FILE__ }
        source = location ? "#{location.path.delete_prefix("#{@root}/")}:#{location.lineno}" : '(outside application/test source)'
        sample = message.to_s.lines.find { |line| !line.strip.empty? }.to_s.strip[0, 240]
      end
      observed, late = @mutex.synchronize do
        label = if @current
                  @current[:name]
                elsif @reported
                  '(late outside a test)'
                elsif @started
                  '(between tests)'
                else
                  '(boot before tests)'
                end
        if error
          groups = @current ? @current[:groups] : @groups
          group = groups[[severity, source]] ||= { count: 0, sample: sample, tests: [] }
          group[:count] += 1
          group[:tests] << label unless @current || group[:tests].include?(label)
        end
        [label, @reported]
      end
      emit "Late #{severity} #{source}: #{sample}; full log: #{@log_path}" if error && late
      observed
    rescue StandardError => e
      emit "Test error-log collection unavailable: #{e.class}; full log: #{@log_path}"
      '(observation unavailable)'
    end

    def merge_groups(groups, name)
      groups.each do |key, group|
        target = @groups[key] ||= { count: 0, sample: group[:sample], tests: [] }
        target[:count] += group[:count]
        target[:tests] << name unless target[:tests].include?(name)
      end
    end
  end

  module Lifecycle
    def run
      TestOutput.start_test("#{self.class}##{name}")
      result = super
    ensure
      TestOutput.finish_test(result)
    end
  end
end
