# frozen_string_literal: true

# Gives handled Rails.error reports a destination in the log. Callers pass a sanitized error whose message is the failing
# class name. Unhandled errors are skipped because the framework already logs them.
class ErrorReportLogSubscriber
  def report(error, handled:, context:, **)
    return unless handled

    # Rails merges the execution context into every report, and during a request it holds the controller and request.
    # Log only what the caller passed.
    caller_context = context.except(*ActiveSupport::ExecutionContext.to_h.keys)
    Rails.logger.error("#{error.message} context=#{caller_context.to_json}\n#{Array(error.backtrace).join("\n")}")
  end
end

Rails.error.subscribe(ErrorReportLogSubscriber.new)
