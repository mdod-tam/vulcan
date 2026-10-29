# frozen_string_literal: true

class SecureCertificationFormsController < SecureRequestFormController
  private

  # Resolved through the certification scope, so a token for any other kind finds nothing.
  def request_form_class = SecureRequestForm.certification_upload
  def request_form_kind_matches? = @secure_request_form.kind_certification_upload?

  def submit_request_form
    Applications::SubmitCertificationUpload.new(
      application: @secure_request_form.application,
      secure_request_form: @secure_request_form,
      file: params[:file]
    ).call
  end

  def assign_display_context
    @constituent_display_name = public_constituent_name(
      @secure_request_form.application.user,
      fallback: t('secure_certification_forms.show.constituent_unknown')
    )
    @application_id = @secure_request_form.application_id
  end

  def form_path = secure_certification_form_path(token: @token)
  def resend_path = new_secure_certification_form_resend_path(token: @token)
  def success_redirect_path = secure_certification_form_success_path(locale: @secure_request_form.delivery_locale)
end
