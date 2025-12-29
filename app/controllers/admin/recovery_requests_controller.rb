# frozen_string_literal: true

module Admin
  class RecoveryRequestsController < ApplicationController
    before_action :authenticate_user!
    before_action :ensure_admin
    before_action :set_recovery_request, only: %i[show approve]

    def index
      @recovery_requests = RecoveryRequest.includes(:user).where(status: 'pending').order(created_at: :desc)
    end

    def show
      # Simply renders the show view with the recovery request found by set_recovery_request
    end

    def approve
      # Transaction to ensure user's credentials are deleted if and only if the status is updated
      ActiveRecord::Base.transaction do
        # Delete all the user's WebAuthn credentials
        @recovery_request.user.webauthn_credentials.destroy_all

        # Update the recovery request status
        @recovery_request.update!(
          status: 'approved',
          resolved_at: Time.current,
          resolved_by_id: current_user.id
        )

        # Notify the user
        notify_user_of_approval
      end

      redirect_to admin_recovery_requests_path, notice: t('.recovery_approved')
    end

    private

    def set_recovery_request
      @recovery_request = RecoveryRequest.find(params[:id])
    end

    def ensure_admin
      return if current_user.admin?

      redirect_to root_path, alert: t('alerts.unauthorized_page')
    end

    def notify_user_of_approval
      # Log the audit event first
      AuditEventService.log(
        action: 'security_key_recovery_approved',
        actor: current_user,
        auditable: @recovery_request,
        metadata: {
          recovery_request_id: @recovery_request.id,
          approved_at: Time.current.iso8601,
          approved_by: current_user.full_name
        }
      )

      # Then, send the notification without the audit flag
      NotificationService.create_and_deliver!(
        type: 'security_key_recovery_approved',
        recipient: @recovery_request.user,
        actor: current_user,
        notifiable: @recovery_request,
        metadata: {
          recovery_request_id: @recovery_request.id,
          approved_at: Time.current.iso8601,
          approved_by: current_user.full_name
        },
        channel: :email
      )
    rescue StandardError => e
      Rails.logger.error "Failed to notify user #{@recovery_request.user_id} of recovery approval: #{e.message}"
      # Don't fail the whole operation if notification fails
    end
  end
end
