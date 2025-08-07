# frozen_string_literal: true

module Admin
  # Provides a shared method for processing application status updates (approve/reject)
  # within admin controllers, handling redirects and flash messages consistently.
  module ApplicationStatusProcessor
    extend ActiveSupport::Concern

    private

    # Processes an application status update action (e.g., :approve, :reject).
    # Assumes the controller has a @application instance variable set.
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
        # Use the shared failure handler
        handle_application_failure(action, failure_message_prefix)
      end
    rescue ::ActiveRecord::RecordInvalid => e
      error_details = e.record.errors.full_messages.to_sentence
      # Use the shared failure handler
      handle_application_failure(action, failure_message_prefix, error_details)
    rescue StandardError => e # Catch other potential errors during the action
      # Use the shared failure handler
      handle_application_failure(action, failure_message_prefix, e.message)
    end

    # Handles application update failures by setting a flash alert and rendering the show action.
    # Assumes the controller responds to `render` and has a `show` template.
    # @param _action [Symbol] The action that failed (unused in current implementation but kept for context).
    # @param prefix [String] The prefix for the alert message.
    # @param error_details [String, nil] Specific error details from validation or exception.
    def handle_application_failure(action_name, prefix, error_details = nil)
      # Pull any ActiveModel errors, or fall back to the passed‑in details or a generic
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
