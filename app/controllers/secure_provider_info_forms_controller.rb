# frozen_string_literal: true

class SecureProviderInfoFormsController < SecureRequestFormController
  private

  def success_page_uses_request_locale?
    true
  end

  def request_form_class = SecureRequestForm
  def request_form_kind_matches? = @secure_request_form.kind_provider_info_request?

  def submit_request_form
    Applications::SubmitProviderInfo.new(
      application: @secure_request_form.application,
      secure_request_form: @secure_request_form,
      params: params.permit(:medical_provider_name, :medical_provider_email, :medical_provider_phone, :medical_provider_fax)
    ).call
  end

  def assign_display_context
    @constituent_name = public_constituent_name(@secure_request_form.application.user)
    @constituent_name_available = @constituent_name.present?
  end

  def form_path = secure_provider_info_form_path(token: @token)
  def resend_path = new_secure_provider_info_form_resend_path(token: @token)
  def success_redirect_path = secure_provider_info_form_success_path(locale: @secure_request_form.delivery_locale)
end
