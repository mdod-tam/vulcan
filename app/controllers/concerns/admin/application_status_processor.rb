# frozen_string_literal: true

module Admin
  # Shared admin approval and rejection responses.
  module ApplicationStatusProcessor
    extend ActiveSupport::Concern

    private

    # The controller must set @application before this call.
    # @param action [Symbol] The action to perform on the application (e.g., :approve, :reject).
    # @param success_message [String, nil] Custom success message (defaults generated).
    # @param failure_message_prefix [String, nil] Custom prefix for failure message (defaults generated).
    def process_application_status_update(action, success_message: nil, failure_message_prefix: nil)
      past_tense = { approve: 'approved', reject: 'rejected' }.fetch(action, action.to_s)
      success_message ||= "Application #{past_tense}."
      failure_message_prefix ||= "Failed to #{action} Application ##{@application.id}"

      if @application.send("#{action}!")
        flash[:notice] = success_message
        redirect_to admin_application_path(@application)
      else
        handle_application_failure(action, failure_message_prefix)
      end
    rescue ::ActiveRecord::RecordInvalid => e
      error_details = e.record.errors.full_messages.to_sentence
      handle_application_failure(action, failure_message_prefix, error_details)
    rescue StandardError => e
      handle_application_failure(action, failure_message_prefix, e.message)
    end

    # Renders admin/applications/show with an alert if the controller supports render.
    # @param action_name [Symbol] The failed action, used in the log if render is unavailable
    # @param prefix [String] The prefix for the alert message.
    # @param error_details [String, nil] Specific error details from validation or exception.
    def handle_application_failure(action_name, prefix, error_details = nil)
      app_errors = (@application.errors.full_messages.to_sentence if @application&.errors&.any?)
      error_message = error_details || app_errors || 'An unexpected error occurred.'

      flash.now[:alert] = "#{prefix}: #{error_message}"

      if respond_to?(:render, true)
        render 'admin/applications/show', status: :unprocessable_content
      else
        Rails.logger.error(
          "Controller does not respond to render. Cannot display failure for action: #{action_name}"
        )
      end
    end
  end
end
