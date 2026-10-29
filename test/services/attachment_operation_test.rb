# frozen_string_literal: true

require 'test_helper'

# AttachmentOperation owns the result shape, timing, and outcome line. The two attachment services have their own
# tests for what each operation does and for the failure contract each keeps.
class AttachmentOperationTest < ActiveSupport::TestCase
  test 'a finished operation returns the shared result keys with its own additions and logs one line' do
    log = StringIO.new

    result = with_logger(log) do
      AttachmentOperation.measure('Proof income approved') do |outcome|
        outcome[:success] = true
        outcome[:blob_size] = 12
      end
    end

    assert_equal true, result[:success]
    assert_nil result[:error]
    assert_equal 12, result[:blob_size]
    assert_kind_of Integer, result[:duration_ms]
    assert_equal 1, log.string.scan(/Proof income approved completed in \d+ms/).size
  end

  test 'the duration covers the operation' do
    started = Time.zone.local(2026, 10, 28, 12)
    Time.stubs(:current).returns(started).then.returns(started + 1.5.seconds)

    result = AttachmentOperation.measure('Op') { |outcome| outcome[:success] = true }

    assert_equal 1500, result[:duration_ms]
  end

  test 'an error is returned in the result, not raised, and logged by class' do
    error = RuntimeError.new('private detail')
    log = StringIO.new

    result = with_logger(log) { AttachmentOperation.measure('Proof income approved') { raise error } }

    assert_equal false, result[:success]
    assert_same error, result[:error]
    assert_equal 1, log.string.scan(/Proof income approved failed in \d+ms: RuntimeError/).size
    assert_not_includes log.string, 'private detail'
  end

  test 'an error after the operation set success still reports failure' do
    result = AttachmentOperation.measure('Op') do |outcome|
      outcome[:success] = true
      raise 'later step failed'
    end

    assert_equal false, result[:success]
    assert_equal 'later step failed', result[:error].message
  end

  test 'on_error runs before the outcome line is logged' do
    order = []
    log = StringIO.new

    with_logger(log) do
      AttachmentOperation.measure('Op', on_error: ->(error) { order << [:on_error, error.message, log.string.empty?] }) { raise 'boom' }
    end

    assert_equal [[:on_error, 'boom', true]], order
  end

  test 'reraise raises the error after the outcome is logged' do
    log = StringIO.new

    error = with_logger(log) do
      assert_raises(ArgumentError) { AttachmentOperation.measure('Op', reraise: true) { raise ArgumentError, 'boom' } }
    end

    assert_equal 'boom', error.message
    assert_equal 1, log.string.scan(/Op failed in \d+ms: ArgumentError/).size
  end

  test 'a digest mismatch in the test environment is logged as an expected failure' do
    log = StringIO.new

    with_logger(log, level: Logger::DEBUG) { AttachmentOperation.measure('Proof id approved') { raise 'Mismatched digest' } }

    assert_match(/\[EXPECTED_TEST_ATTACHMENT\] Proof id approved failed in \d+ms: RuntimeError/, log.string)
  end

  test 'a logging failure does not change the operation result' do
    Rails.logger.stubs(:info).raises(RuntimeError, 'log sink down')
    Rails.logger.stubs(:error)

    result = AttachmentOperation.measure('Op') { |outcome| outcome[:success] = true }

    assert_equal true, result[:success]
  end

  private

  def with_logger(io, level: Logger::INFO, &)
    logger = ActiveSupport::Logger.new(io)
    logger.level = level
    Rails.stub(:logger, logger, &)
  end
end
