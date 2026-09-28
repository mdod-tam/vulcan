# frozen_string_literal: true

class SecureCertificationFormResendsController < SecureRequestResendController
  private

  def request_form_class = MedicalProviderSecureRequestForm
  def request_form_kind_matches? = @secure_request_form.kind_certification_upload?

  def request_replacement_link
    Applications::RequestCertificationUpload.new(
      application: @secure_request_form.application,
      actor: @secure_request_form.requested_by || User.system_user,
      resend_of: @secure_request_form,
      public_recovery: true,
      deliver_email: true
    ).call
  end

  def form_path = secure_certification_form_path(token: @token)
  def sent_path(**) = secure_certification_form_resend_sent_path(**)
  def rate_limit_key = 'secure_certification_form_resend'
  def resend_log_label = 'Certification upload'

  def resend_log_context
    { application_id: @secure_request_form.application_id, medical_provider_secure_request_form_id: @secure_request_form.id }
  end
end
