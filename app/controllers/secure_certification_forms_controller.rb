# frozen_string_literal: true

class SecureCertificationFormsController < SecureRequestFormController
  private

  def request_form_class = MedicalProviderSecureRequestForm
  def request_form_kind_matches? = @secure_request_form.kind_certification_upload?

  def submit_request_form
    Applications::SubmitCertificationUpload.new(
      application: @secure_request_form.application,
      medical_provider_secure_request_form: @secure_request_form,
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

  def resend_path = new_secure_certification_form_resend_path(token: @token)
  def success_redirect_path = secure_certification_form_success_path

  def locale_recipient_for_request
    @secure_request_form&.application&.user
  end
end
