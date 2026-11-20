# frozen_string_literal: true

module ApplicationFormHandling
  extend ActiveSupport::Concern

  included do
    helper_method :redirect_with_notice, :redirect_with_alert
  end

  def redirect_with_notice(path, notice)
    redirect_to path, notice: notice
  end

  def redirect_with_alert(path, alert)
    redirect_to path, alert: alert
  end

  def determine_success_message(application, is_submission: false)
    if is_submission || application.status_in_progress?
      'Application submitted successfully!'
    else
      'Application saved as draft.'
    end
  end

  # Logs the failure and returns false.
  def handle_transaction_failure?(exception, context)
    Rails.logger.error("Transaction failed during #{context}: #{exception.class.name}")
    false
  end

  def log_debug(message)
    Rails.logger.debug(message) if Rails.env.local?
  end

  def log_error(message, exception = nil)
    Rails.logger.error([message, exception&.class&.name].compact.join(': '))
  end
end
