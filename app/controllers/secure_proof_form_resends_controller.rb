# frozen_string_literal: true

class SecureProofFormResendsController < SecureRequestResendController
  private

  def request_form_class = SecureRequestForm

  def request_form_kind_matches?
    @secure_request_form.kind.in?(Applications::SubmitProofResubmission::KIND_TO_PROOF_TYPE.keys)
  end

  def request_replacement_link
    Applications::RequestProofResubmission.new(
      application: @secure_request_form.application,
      actor: @secure_request_form.requested_by || User.system_user,
      proof_type: Applications::SubmitProofResubmission::KIND_TO_PROOF_TYPE.fetch(@secure_request_form.kind),
      resend_of: @secure_request_form,
      public_recovery: true
    ).call
  end

  def form_path = secure_proof_form_path(token: @token)
  def rate_limit_key = 'secure_proof_form_resend'
  def resend_log_label = 'Proof resubmission'

  def resend_log_context
    {
      application_id: @secure_request_form.application_id,
      secure_request_form_id: @secure_request_form.id,
      recipient_id: @secure_request_form.recipient_id,
      recipient_channel: @secure_request_form.recipient_channel
    }
  end
end
