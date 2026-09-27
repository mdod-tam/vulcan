# frozen_string_literal: true

# Shared show/update flow for the public secure forms. Each subclass names its
# form model, kind check, submission service, and paths.
class SecureRequestFormController < SecurePublicFormController
  layout 'secure_public'

  before_action :set_secure_request_form, only: %i[show update]
  around_action :with_request_locale, only: %i[show update]
  around_action :with_success_locale, only: :success

  def show
    return render_unavailable unless request_form_kind?
    return render_unavailable if @secure_request_form.revoked? && revoked_hides_submission?
    return render_submitted if @secure_request_form.submitted?
    return render_unavailable if @secure_request_form.revoked?
    return redirect_to resend_path if @secure_request_form.expired?

    assign_display_context
  end

  def update
    return render_unavailable unless request_form_kind? && !@secure_request_form.revoked?
    return render_submitted if @secure_request_form.submitted?
    return redirect_to resend_path if @secure_request_form.expired?

    result = submit_request_form
    return redirect_to success_redirect_path if result.success?
    return render_submitted if @secure_request_form.reload.submitted?

    @form_errors = result.data&.fetch(:errors, nil)
    @form_error_message = result.message if @form_errors.blank?
    assign_display_context
    render :show, status: :unprocessable_content
  end

  def success; end

  private

  def set_secure_request_form
    @token = params[:token]
    @secure_request_form = request_form_class.from_public_token(@token)
  end

  def request_form_kind?
    @secure_request_form.present? && request_form_kind_matches?
  end

  # Provider-info pages show a revoked link as unavailable even after submission.
  def revoked_hides_submission?
    false
  end

  def assign_display_context; end

  def with_success_locale(&)
    success_page_uses_request_locale? ? with_public_request_locale(&) : yield
  end

  # Proof and provider-info success pages follow the locale in the redirect.
  def success_page_uses_request_locale?
    false
  end

  def request_form_class = raise(NotImplementedError)
  def request_form_kind_matches? = raise(NotImplementedError)
  def submit_request_form = raise(NotImplementedError)
  def resend_path = raise(NotImplementedError)
  def success_redirect_path = raise(NotImplementedError)
end
