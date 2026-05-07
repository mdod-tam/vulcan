# frozen_string_literal: true

class SecureProofFormResendsController < SecurePublicFormController
  layout 'secure_public'

  before_action :set_secure_request_form, only: %i[new create]
  around_action :with_request_locale, only: %i[new create]

  def new
    return render_unavailable if @secure_request_form.blank? || @secure_request_form.revoked? || @secure_request_form.submitted?
    return render_unavailable unless proof_request_form?

    redirect_to secure_proof_form_path(token: @token) unless @secure_request_form.expired?
  end

  def create
    if proof_resend_allowed?
      if rate_limited?
        Rails.logger.warn("Secure proof form resend rate limited: #{rate_limit_context.inspect}")
      else
        result = Applications::RequestProofResubmission.new(
          application: @secure_request_form.application,
          actor: @secure_request_form.requested_by || User.system_user,
          proof_type: proof_type,
          resend_of: @secure_request_form,
          public_recovery: true
        ).call
        log_resend_failure(result) if result.failure?
      end
    end

    render :create, status: :ok
  end

  private

  def proof_resend_allowed?
    @secure_request_form.present? &&
      proof_request_form? &&
      !@secure_request_form.revoked? &&
      !@secure_request_form.submitted? &&
      @secure_request_form.expired?
  end

  def proof_request_form?
    @secure_request_form.kind.in?(Applications::SubmitProofResubmission::KIND_TO_PROOF_TYPE.keys)
  end

  def proof_type
    Applications::SubmitProofResubmission::KIND_TO_PROOF_TYPE.fetch(@secure_request_form.kind)
  end

  def rate_limited?
    RateLimit.check!(:proof_submission, "secure_proof_form_resend:#{request.remote_ip}")
    false
  rescue RateLimit::ExceededError
    true
  rescue ArgumentError => e
    Rails.logger.warn("Secure proof form resend rate limit unavailable: #{e.message}")
    false
  end

  def rate_limit_context
    {
      application_id: @secure_request_form.application_id,
      secure_request_form_id: @secure_request_form.id,
      remote_ip: request.remote_ip
    }
  end

  def log_resend_failure(result)
    context = {
      application_id: @secure_request_form.application_id,
      secure_request_form_id: @secure_request_form.id,
      recipient_id: @secure_request_form.recipient_id,
      recipient_channel: @secure_request_form.recipient_channel,
      proof_type: proof_type,
      message: result.message
    }

    Rails.logger.warn("Proof resubmission resend request failed: #{context.inspect}")
  end

  def set_secure_request_form
    @token = resend_params[:token]
    @secure_request_form = SecureRequestForm.from_public_token(@token)
  end

  def resend_params
    params.permit(:token)
  end
end
