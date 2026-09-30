# frozen_string_literal: true

# Shared flow for requesting a new link after a public secure form expires.
# The response is the same whatever happens, so it does not reveal whether a link exists.
class SecureRequestResendController < SecurePublicFormController
  layout 'secure_public'

  before_action :set_secure_request_form, only: %i[new create]
  around_action :with_request_locale, only: %i[new create]
  around_action :with_public_request_locale, only: :sent

  def new
    return render_unavailable unless request_form_kind?
    return render_unavailable if @secure_request_form.revoked? || @secure_request_form.submitted?

    redirect_to form_path unless @secure_request_form.expired?
  end

  def create
    if resend_allowed?
      if rate_limited?
        Rails.logger.warn("#{resend_log_label} resend rate limited: #{resend_log_context.merge(remote_ip: request.remote_ip).inspect}")
      elsif (@resend_actor = @secure_request_form.requested_by || User.system_user)
        result = request_replacement_link
        Rails.logger.warn("#{resend_log_label} resend request failed: #{resend_log_context.merge(message: result.message).inspect}") if result.failure?
      end
    end

    # Redirect so the browser and Turbo land on a GET page. The locale is the
    # one this request already used, so the redirect reveals nothing new.
    redirect_to sent_path(locale: I18n.locale), status: :see_other
  end

  def sent
    render_html_response :create
  end

  private

  attr_reader :resend_actor

  def set_secure_request_form
    @token = params[:token]
    @secure_request_form = request_form_class.from_public_token(@token)
  end

  def request_form_kind?
    @secure_request_form.present? && request_form_kind_matches?
  end

  def resend_allowed?
    request_form_kind? &&
      !@secure_request_form.revoked? &&
      !@secure_request_form.submitted? &&
      @secure_request_form.expired?
  end

  def rate_limited?
    RateLimit.check!(:proof_submission, "#{rate_limit_key}:#{request.remote_ip}")
    false
  rescue RateLimit::ExceededError
    true
  rescue ArgumentError => e
    Rails.logger.warn("#{resend_log_label} resend rate limit unavailable: #{e.message}")
    false
  end

  def request_form_class = raise(NotImplementedError)
  def request_form_kind_matches? = raise(NotImplementedError)
  def request_replacement_link = raise(NotImplementedError)
  def form_path = raise(NotImplementedError)
  def sent_path(**) = raise(NotImplementedError)
  def rate_limit_key = raise(NotImplementedError)
  def resend_log_label = raise(NotImplementedError)
  def resend_log_context = raise(NotImplementedError)
end
