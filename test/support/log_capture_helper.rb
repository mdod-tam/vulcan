# frozen_string_literal: true

module LogCaptureHelper
  def capture_rails_logs
    original_logger = Rails.logger
    log_output = StringIO.new
    Rails.logger = ActiveSupport::Logger.new(log_output)

    yield

    log_output.string
  ensure
    Rails.logger = original_logger
  end
end

ActiveSupport.on_load(:active_support_test_case) do
  include LogCaptureHelper
end
