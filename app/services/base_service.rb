# frozen_string_literal: true

# Base class for all service objects in the application
# Provides common functionality and structure
class BaseService
  include SecureErrorSanitizer

  attr_reader :errors

  # Default result object returned by services
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
    # Base initialization - may be overridden by subclasses
  end

  # Returns a success result with optional message and data
  def success(message = nil, data = nil)
    Result.new(success: true, message: message, data: data)
  end

  # Returns a failure result with optional message and data
  def failure(message = nil, data = nil)
    Result.new(success: false, message: message, data: data)
  end

  protected

  # Add an error message to the errors array
  def add_error(message)
    @errors << message
    false
  end

  # Backward-compatible boolean-style helper used by some older services.
  def add_error?(message)
    add_error(message)
  end

  # Log an error with optional context and add to errors array
  def log_error(exception, context = nil)
    error_message = if context.is_a?(String)
                      "#{self.class.name}: #{context} - #{exception.message}"
                    elsif context.is_a?(Hash)
                      "#{self.class.name}: #{exception.message} | Context: #{context.inspect}"
                    else
                      "#{self.class.name}: #{exception.message}"
                    end

    Rails.logger.error error_message
    Rails.logger.error exception.backtrace.join("\n") if exception.backtrace

    add_error(exception.message)
  end
end
