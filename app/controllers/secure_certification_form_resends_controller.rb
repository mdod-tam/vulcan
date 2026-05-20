# frozen_string_literal: true

class SecureCertificationFormResendsController < SecurePublicFormController
  layout 'secure_public'

  before_action :set_secure_request_form, only: %i[new create]
  around_action :with_request_locale, only: %i[new create]

  def new
    return render_unavailable if @secure_request_form.blank? || @secure_request_form.revoked? || @secure_request_form.submitted?
    return render_unavailable unless certification_request_form?

    redirect_to secure_certification_form_path(token: @token) unless @secure_request_form.expired?
  end

  def create
    if certification_resend_allowed?
      if rate_limited?
        Rails.logger.warn("Secure certification form resend rate limited: #{rate_limit_context.inspect}")
      else
        result = request_replacement_link
        log_resend_failure(result) if result.failure?
      end
    end

    render_html_response :create
  end

  private

  def certification_resend_allowed?
    @secure_request_form.present? &&
      certification_request_form? &&
      !@secure_request_form.revoked? &&
      !@secure_request_form.submitted? &&
      @secure_request_form.expired?
  end

  def certification_request_form?
    @secure_request_form.kind_certification_upload?
  end

  def request_replacement_link
    Applications::RequestCertificationUpload.new(
      application: @secure_request_form.application,
      actor: @secure_request_form.requested_by || User.system_user,
      resend_of: @secure_request_form,
      public_recovery: true,
      deliver_email: true
    ).call
  end

  def rate_limited?
    RateLimit.check!(:proof_submission, "secure_certification_form_resend:#{request.remote_ip}")
    false
  rescue RateLimit::ExceededError
    true
  rescue ArgumentError => e
    Rails.logger.warn("Secure certification form resend rate limit unavailable: #{e.message}")
    false
  end

  def rate_limit_context
    resend_failure_context.merge(remote_ip: request.remote_ip)
  end

  def log_resend_failure(result)
    Rails.logger.warn("Certification upload resend request failed: #{resend_failure_context.merge(message: result.message).inspect}")
  end

  def resend_failure_context
    {
      application_id: @secure_request_form.application_id,
      medical_provider_secure_request_form_id: @secure_request_form.id
    }
  end

  def set_secure_request_form
    @token = params[:token]
    @secure_request_form = MedicalProviderSecureRequestForm.from_public_token(@token)
  end

  def locale_recipient_for_request
    @secure_request_form&.application&.user
  end
end
