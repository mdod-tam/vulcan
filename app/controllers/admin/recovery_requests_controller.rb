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
      approval_result = approve_pending_request
      if approval_result == :not_pending
        redirect_to admin_recovery_request_path(@recovery_request), alert: t('.not_pending')
        return
      elsif approval_result == :notification_failed
        redirect_to admin_recovery_request_path(@recovery_request), alert: t('.notification_failed')
        return
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

    def approve_pending_request
      result = :not_pending

      ActiveRecord::Base.transaction do
        @recovery_request.lock!
        if @recovery_request.pending?
          approved_at = Time.current
          @recovery_request.user.webauthn_credentials.destroy_all
          @recovery_request.update!(
            status: 'approved',
            resolved_at: approved_at,
            resolved_by_id: current_user.id
          )

          notification = create_approval_notification(approved_at)
          if approval_notification_successful?(notification)
            result = :approved
          else
            result = :notification_failed
            raise ActiveRecord::Rollback
          end
        end
      end

      @recovery_request.reload if result == :notification_failed
      result
    rescue StandardError => e
      Rails.logger.error "Failed to approve recovery request #{@recovery_request.id}: #{e.message}"
      @recovery_request.reload
      :notification_failed
    end

    def create_approval_notification(approved_at)
      metadata = approval_notification_metadata(approved_at)

      # Log the audit event first
      AuditEventService.log(
        action: 'security_key_recovery_approved',
        actor: current_user,
        auditable: @recovery_request,
        metadata: metadata
      )

      # Then, send the notification without the audit flag
      NotificationService.create_and_deliver!(
        type: 'security_key_recovery_approved',
        recipient: @recovery_request.user,
        actor: current_user,
        notifiable: @recovery_request,
        metadata: metadata,
        channel: :email
      )
    end

    def approval_notification_metadata(approved_at)
      {
        recovery_request_id: @recovery_request.id,
        approved_at: approved_at.iso8601,
        approved_by: current_user.full_name
      }
    end

    def approval_notification_successful?(notification)
      notification.respond_to?(:persisted?) &&
        notification.persisted? &&
        notification.delivery_status != 'error'
    end
  end
end
