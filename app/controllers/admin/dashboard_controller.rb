# frozen_string_literal: true

module Admin
  class DashboardController < ApplicationController
    before_action :require_admin!
    include Pagy::Backend
    include DashboardMetricsLoading

    def index
      redirect_to admin_applications_path
    end

    private

    # Dashboard metrics loading is handled in the DashboardMetricsLoading concern

    def calculate_training_requests
      # Try notifications first, fallback to training sessions
      notification_count = Notification.where(action: 'training_requested', notifiable_type: 'Application')
                                       .select(:notifiable_id)
                                       .distinct
                                       .count

      return notification_count if notification_count.positive?

      Application.joins(:training_sessions)
                 .where(training_sessions: { status: %i[requested scheduled confirmed] })
                 .distinct
                 .count
    end

    # Safely assigns a value to an instance variable after sanitizing the key
    # @param key [String, Symbol] The variable name, without the '@' prefix
    # @param value [Object] The value to assign
    def safe_assign(key, value)
      # Strip leading @ if present and sanitize key to ensure valid Ruby variable name
      sanitized_key = key.to_s.sub(/\A@/, '').gsub(/[^0-9a-zA-Z_]/, '_')
      instance_variable_set("@#{sanitized_key}", value)
    end

    def build_application_scope
      Application.includes(:user, :income_proof_attachment, :residency_proof_attachment)
                 .where.not(status: %i[rejected archived])
                 .order(created_at: :desc)
    end

    def apply_filter(scope, filter)
      case filter
      when 'in_progress'
        scope.where(status: :in_progress)
      when 'approved'
        scope.where(status: :approved)
      when 'proofs_needing_review'
        scope.where(income_proof_status: 0)
             .or(scope.where(residency_proof_status: 0))
      when 'awaiting_medical_response'
        scope.where(status: :awaiting_dcf)
      when 'training_requests'
        # Filter applications with training request notifications
        application_ids = Notification.where(action: 'training_requested')
                                      .where(notifiable_type: 'Application')
                                      .pluck(:notifiable_id)
        # Debug output to help diagnose the issue
        Rails.logger.debug { "Training requests filter found IDs: #{application_ids.inspect}" }

        # The issue might be that the application is filtered out by the base scope
        # Use unscoped to avoid default scopes for just this specific filter
        if application_ids.present?
          # Ensure we include applications regardless of their status
          Application.where(id: application_ids)
        else
          # Empty result set if no training requests found
          scope.none
        end
      else
        scope
      end
    end
  end
end
