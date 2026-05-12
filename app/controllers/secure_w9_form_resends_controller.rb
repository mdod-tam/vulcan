# frozen_string_literal: true

class SecureW9FormResendsController < SecurePublicFormController
  layout 'secure_public'

  before_action :set_secure_request_form, only: %i[new create]
  around_action :with_request_locale, only: %i[new create]

  def new
    return render_unavailable if @secure_request_form.blank? || @secure_request_form.revoked? || @secure_request_form.submitted?
    return render_unavailable unless w9_request_form?

    redirect_to secure_w9_form_path(token: @token) unless @secure_request_form.expired?
  end

  def create
    if w9_resend_allowed?
      if rate_limited?
        Rails.logger.warn("Secure W9 form resend rate limited: #{rate_limit_context.inspect}")
      else
        result = Vendors::RequestW9Resubmission.new(
          vendor: @secure_request_form.vendor,
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

  def w9_resend_allowed?
    @secure_request_form.present? &&
      w9_request_form? &&
      !@secure_request_form.revoked? &&
      !@secure_request_form.submitted? &&
      @secure_request_form.expired?
  end

  def w9_request_form?
    @secure_request_form.kind_w9_upload?
  end

  def rate_limited?
    RateLimit.check!(:proof_submission, "secure_w9_form_resend:#{request.remote_ip}")
    false
  rescue RateLimit::ExceededError
    true
  rescue ArgumentError => e
    Rails.logger.warn("Secure W9 form resend rate limit unavailable: #{e.message}")
    false
  end

  def rate_limit_context
    {
      vendor_id: @secure_request_form.vendor_id,
      vendor_secure_request_form_id: @secure_request_form.id,
      remote_ip: request.remote_ip
    }
  end

  def log_resend_failure(result)
    Rails.logger.warn(
      "W9 resubmission resend request failed: #{rate_limit_context.except(:remote_ip).merge(message: result.message).inspect}"
    )
  end

  def set_secure_request_form
    @token = params[:token]
    @secure_request_form = VendorSecureRequestForm.from_public_token(@token)
  end

  def locale_recipient_for_request
    @secure_request_form&.vendor
  end
end
