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
      Application.with_pending_training_request.count
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
        scope.with_proofs_needing_review
      when 'awaiting_medical_response'
        scope.where(status: :awaiting_dcf)
      when 'training_requests'
        scope.with_pending_training_request
      else
        scope
      end
    end
  end
end
