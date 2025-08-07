# frozen_string_literal: true

module TurboStreamResponseHandling
  extend ActiveSupport::Concern

  # Handles successful turbo stream responses with standardized patterns
  # @param message [String] The success message to display
  # @param updates [Hash] Hash of element_id => partial_name for updates
  # @param modals_to_remove [Array<String>] Array of modal IDs to remove
  def handle_turbo_stream_success(message:, updates: {}, modals_to_remove: [])
    prepare_turbo_stream_data if respond_to?(:prepare_turbo_stream_data, true)
    flash.now[:success] = message
    streams = build_success_turbo_streams(updates, modals_to_remove)
    render turbo_stream: streams
  end

  # Handles failed turbo stream responses with error messaging
  # @param message [String] The error message to display
  def handle_turbo_stream_error(message:)
    flash.now[:error] = message
    render turbo_stream: turbo_stream.update('flash', partial: 'shared/flash')
  end

  # Builds turbo stream responses for successful operations
  # @param updates [Hash] Hash of element_id => partial_name for updates
  # @param modals_to_remove [Array<String>] Array of modal IDs to remove
  # @return [Array] Array of turbo stream objects
  def build_success_turbo_streams(updates = {}, modals_to_remove = [])
    streams = []

    # Always update flash messages
    streams << turbo_stream.update('flash', partial: 'shared/flash')

    # Add custom updates
    updates.each do |element_id, partial_name|
      streams << turbo_stream.update(element_id, partial: partial_name)
    end

    # Remove specified modals
    modals_to_remove.each do |modal_id|
      streams << turbo_stream.remove(modal_id)
    end

    streams
  end

  # Standard set of modals to remove for application-related operations
  def standard_application_modals
    %w[
      proofRejectionModal
      incomeProofReviewModal
      residencyProofReviewModal
      medicalCertificationReviewModal
    ]
  end

  # Builds turbo streams for application proof review success
  def build_proof_review_success_streams
    updates = {
      'attachments-section' => 'attachments',
      'audit-logs' => 'audit_logs'
    }

    build_success_turbo_streams(updates, standard_application_modals)
  end

  # Handles both HTML and Turbo Stream responses for successful operations
  # @param html_redirect_path [String] Path to redirect for HTML requests
  # @param html_message [String] Message for HTML redirect
  # @param turbo_message [String] Message for Turbo Stream response
  # @param turbo_updates [Hash] Updates for Turbo Stream response
  # @param turbo_modals_to_remove [Array<String>] Modals to remove for Turbo Stream
  # @param turbo_redirect_path [String] Path to redirect for Turbo Stream (optional)
  def handle_success_response(
    html_redirect_path:,
    html_message:,
    turbo_message: nil,
    turbo_updates: {},
    turbo_modals_to_remove: [],
    turbo_redirect_path: nil
  )
    turbo_message ||= html_message

    respond_to do |format|
      # Keep traditional flash types for HTML redirects to avoid breaking existing tests.
      format.html { redirect_to html_redirect_path, notice: html_message }

      format.turbo_stream do
        if turbo_redirect_path.present?
          # Standard HTTP redirect – Turbo will convert this into a visit
          redirect_to turbo_redirect_path, status: :see_other, notice: turbo_message
        else
          handle_turbo_stream_success(
            message: turbo_message,
            updates: turbo_updates,
            modals_to_remove: turbo_modals_to_remove
          )
        end
      end
    end
  end

  # Handles both HTML and Turbo Stream responses for failed operations
  # @param html_redirect_path [String] Path to redirect for HTML requests (optional)
  # @param html_render_action [Symbol] Action to render for HTML requests (optional)
  # @param error_message [String] Error message to display
  # @param status [Symbol] HTTP status for render (optional, defaults to :unprocessable_content)
  def handle_error_response(error_message:, html_redirect_path: nil, html_render_action: nil, status: :unprocessable_content)
    respond_to do |format|
      if html_redirect_path
        format.html { redirect_to html_redirect_path, alert: error_message }
      elsif html_render_action
        format.html do
          flash.now[:alert] = error_message
          render html_render_action, status: status
        end
      else
        format.html { redirect_back(fallback_location: root_path, alert: error_message) }
      end

      format.turbo_stream { handle_turbo_stream_error(message: error_message) }
    end
  end
end
