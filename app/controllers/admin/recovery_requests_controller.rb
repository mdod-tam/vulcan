# frozen_string_literal: true

module Admin
  class RecoveryRequestsController < BaseController
    before_action :set_recovery_request, only: %i[show approve retry_notice]

    def index
      @recovery_requests = RecoveryRequest.includes(:user).pending.order(created_at: :desc)
    end

    def show
      prepare_show
    end

    def approve
      result = RecoveryRequests::Approve.new(recovery_request: @recovery_request, actor: current_user,
                                             session_record: current_session, token: presented_session_token,
                                             verification: verification_params).call
      respond_to_approval(result)
    rescue Session::AuthenticationRequired
      redirect_to new_reauthentication_path(return_to: admin_recovery_request_path(@recovery_request)),
                  alert: 'Verify your password and existing factor before approving this request.', status: :see_other
    rescue StandardError => e
      Rails.logger.error("Recovery approval outcome could not be confirmed for request #{@recovery_request.id}: #{e.class.name}")
      redirect_to admin_recovery_request_path(@recovery_request),
                  alert: 'Approval could not be confirmed. Review the request status before trying again.', status: :see_other
    end

    def retry_notice
      User.transaction do
        actor = User.lock_for_merge_integrity!(current_user).fetch(current_user.id)
        current_session&.require_recent_authentication!(token: presented_session_token, user: actor) || raise(Session::AuthenticationRequired)
        raise Session::AuthenticationRequired unless actor.admin?
      end
      outcome = RecoveryRequests::DispatchApprovalNotice.new(@recovery_request, refresh_failed_context: true).call
      message = case outcome
                when :queued then 'The recovery notice is queued. Approval was not repeated.'
                when :already_submitted then 'This notice has already been handed off or has a delivery attempt that requires review.'
                when :failed then 'Recovery remains approved. The notice could not be queued; review its delivery status.'
                else 'No approved recovery notice is available.'
                end
      redirect_to admin_recovery_request_path(@recovery_request), notice: message, status: :see_other
    rescue Session::AuthenticationRequired
      redirect_to new_reauthentication_path(return_to: admin_recovery_request_path(@recovery_request)), status: :see_other
    end

    private

    def prepare_show
      @approval_notification = @recovery_request.approval_notification
      @credentials = @recovery_request.user.webauthn_credentials.order(:id).to_a
      @recent_authentication = current_session&.freshly_authenticated?(user: current_user)
    end

    def set_recovery_request
      @recovery_request = RecoveryRequest.find(params.expect(:id))
    end

    def verification_params
      params.fetch(:recovery_request, ActionController::Parameters.new).permit(
        :verification_method, :verification_result, :verification_reference, :identity_check_completed
      )
    end

    def respond_to_approval(result)
      case result.status
      when :approved
        redirect_to admin_recovery_request_path(@recovery_request),
                    notice: 'Security-key recovery approved. All account sessions were revoked; review the notice status below.', status: :see_other
      when :approved_notice_failed
        redirect_to admin_recovery_request_path(@recovery_request),
                    alert: 'Security-key recovery is approved and sessions were revoked. Its notice could not be queued.', status: :see_other
      when :invalid
        prepare_show
        render :show, status: :unprocessable_content
      else
        message = case result.status
                  when :not_pending then 'This request has already been resolved.'
                  when :self_approval then 'A different administrator must approve your recovery request.'
                  when :ineligible then 'This account is no longer eligible for public sign-in.'
                  else 'You are not authorized to approve this recovery request.'
                  end
        redirect_to admin_recovery_request_path(@recovery_request), alert: message, status: :see_other
      end
    end
  end
end
