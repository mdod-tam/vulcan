# frozen_string_literal: true

# Base class for service objects: the Result struct, error collection, and error logging.
#
# Result contract: success? and failure? say whether the service did its job, message is the display-ready outcome copy,
# and data carries the details a caller needs to choose its response. A service whose callers branch on more than that
# returns its own value object instead of widening Result, such as Applications::ApplicationCreator::Result (field
# errors and a pending-review flag), VoucherVerificationService::VerificationResult (message key and attempts left), or
# Users::CapabilityWriter::Result (a status symbol). No universal Result type is planned.
class BaseService
  include SecureErrorSanitizer

  attr_reader :errors

  Result = Struct.new(:success, :message, :data) do
    def success?
      success == true
    end

    def failure?
      !success?
    end
  end

  def initialize(*_args)
    @errors = []
  end

  def success(message = nil, data = nil)
    Result.new(success: true, message: message, data: data)
  end

  def failure(message = nil, data = nil)
    Result.new(success: false, message: message, data: data)
  end

  protected

  # Records the message and returns false.
  def add_error(message)
    @errors << message
    false
  end

  # Logs the exception class with optional context, then records the exception message.
  def log_error(exception, context = nil)
    error_message = if context.is_a?(String)
                      "#{self.class.name}: #{context} - #{exception.class.name}"
                    elsif context.is_a?(Hash)
                      "#{self.class.name}: #{exception.class.name} | Context: #{context.inspect}"
                    else
                      "#{self.class.name}: #{exception.class.name}"
                    end

    Rails.logger.error error_message

    add_error(exception.message)
  end
end
