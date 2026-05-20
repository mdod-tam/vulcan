# frozen_string_literal: true

class SecureProviderInfoFormResendsController < SecurePublicFormController
  layout 'secure_public'

  before_action :set_secure_request_form, only: %i[new create]
  around_action :with_request_locale, only: %i[new create]

  def new
    return render_unavailable unless provider_info_form?
    return render_unavailable if @secure_request_form.revoked? || @secure_request_form.submitted?

    redirect_to secure_provider_info_form_path(token: @token) unless @secure_request_form.expired?
  end

  def create
    if provider_info_form? && !@secure_request_form.revoked? && !@secure_request_form.submitted? &&
       @secure_request_form.expired?
      if rate_limited?
        Rails.logger.warn("Provider-info resend rate limited: #{resend_context.merge(remote_ip: request.remote_ip).inspect}")
      else
        result = Applications::RequestProviderInfo.new(
          application: @secure_request_form.application,
          actor: @secure_request_form.requested_by || User.system_user,
          resend_of: @secure_request_form,
          public_recovery: true
        ).call
        log_resend_failure(result) if result.failure?
      end
    end

    render_html_response :create
  end

  private

  def provider_info_form?
    @secure_request_form.present? && @secure_request_form.kind_provider_info_request?
  end

  def rate_limited?
    RateLimit.check!(:proof_submission, "secure_provider_info_form_resend:#{request.remote_ip}")
    false
  rescue RateLimit::ExceededError
    true
  rescue ArgumentError => e
    Rails.logger.warn("Provider-info resend rate limit unavailable: #{e.message}")
    false
  end

  def log_resend_failure(result)
    Rails.logger.warn("Provider-info resend request failed: #{resend_context.merge(message: result.message).inspect}")
  end

  def resend_context
    {
      application_id: @secure_request_form.application_id,
      secure_request_form_id: @secure_request_form.id,
      recipient_id: @secure_request_form.recipient_id,
      recipient_channel: @secure_request_form.recipient_channel
    }
  end

  def set_secure_request_form
    @token = params[:token]
    @secure_request_form = SecureRequestForm.from_public_token(@token)
  end
end
