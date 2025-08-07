# frozen_string_literal: true

module ApplicationFormHandling
  extend ActiveSupport::Concern

  included do
    # Utility methods for form handling
    helper_method :redirect_with_notice, :redirect_with_alert
  end

  # Common form error handling
  def render_form_errors(form, application = nil)
    @application = application || Application.new(filtered_application_params)

    # Only process form errors if form is present
    if form.respond_to?(:errors)
      form.errors.each do |error|
        @application.errors.add(error.attribute, error.message)
      end
    end

    initialize_address_and_provider_for_form
    render action_name == 'update' ? :edit : :new, status: :unprocessable_content
  end

  # Common redirect helpers
  def redirect_with_notice(path, notice)
    redirect_to path, notice: notice
  end

  def redirect_with_alert(path, alert)
    redirect_to path, alert: alert
  end

  # Common form preparation
  def initialize_address_and_provider_for_form
    initialize_address if respond_to?(:initialize_address, true)
    build_medical_provider_for_form if respond_to?(:build_medical_provider_for_form, true)
  end

  # Common success message determination
  def determine_success_message(application, is_submission: false)
    if is_submission || application.status_in_progress?
      'Application submitted successfully!'
    else
      'Application saved as draft.'
    end
  end

  # Handle transaction failures consistently
  def handle_transaction_failure?(exception, context)
    Rails.logger.error("Transaction failed during #{context}: #{exception.message}")
    Rails.logger.error(exception.backtrace.join("\n")) if exception.backtrace
    false
  end

  # Common logging helpers
  def log_debug(message)
    Rails.logger.debug(message) if Rails.env.local?
  end

  def log_error(message, exception = nil)
    Rails.logger.error(message)
    Rails.logger.error(exception.backtrace.join("\n")) if exception&.backtrace
  end
end
