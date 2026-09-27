# frozen_string_literal: true

class SecureProofFormsController < SecureRequestFormController
  private

  def success_page_uses_request_locale?
    true
  end

  def request_form_class = SecureRequestForm

  def request_form_kind_matches?
    @secure_request_form.kind.in?(Applications::SubmitProofResubmission::KIND_TO_PROOF_TYPE.keys)
  end

  def submit_request_form
    Applications::SubmitProofResubmission.new(
      application: @secure_request_form.application,
      secure_request_form: @secure_request_form,
      file: params[:file]
    ).call
  end

  def assign_display_context
    proof_type = Applications::SubmitProofResubmission::KIND_TO_PROOF_TYPE.fetch(@secure_request_form.kind)
    @proof_type_label = t("secure_proof_forms.proof_types.#{proof_type}")
  end

  def form_path = secure_proof_form_path(token: @token)
  def resend_path = new_secure_proof_form_resend_path(token: @token)
  def success_redirect_path = secure_proof_form_success_path(locale: @secure_request_form.delivery_locale)
end
