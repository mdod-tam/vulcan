# frozen_string_literal: true

# Gives handled Rails.error reports a destination in the log. Callers pass DiagnosticReport's sanitized error, so the
# message is the failing class name. Unhandled errors are skipped because the framework already logs them.
class ErrorReportLogSubscriber
  def report(error, handled:, context:, **)
    return unless handled

    Rails.logger.error("#{error.message} context=#{context.to_json}\n#{Array(error.backtrace).join("\n")}")
  end
end

Rails.error.subscribe(ErrorReportLogSubscriber.new)
