# frozen_string_literal: true

# Base class for service objects: the Result struct, error collection, and error logging.
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

  # Same as add_error, for call sites that read as a predicate.
  def add_error?(message)
    add_error(message)
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
