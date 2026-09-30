# frozen_string_literal: true

class SecureProviderInfoFormResendsController < SecureRequestResendController
  private

  def request_form_class = SecureRequestForm
  def request_form_kind_matches? = @secure_request_form.kind_provider_info_request?

  def request_replacement_link
    Applications::RequestProviderInfo.new(
      application: @secure_request_form.application,
      actor: resend_actor,
      resend_of: @secure_request_form,
      public_recovery: true
    ).call
  end

  def form_path = secure_provider_info_form_path(token: @token)
  def sent_path(**) = secure_provider_info_form_resend_sent_path(**)
  def rate_limit_key = 'secure_provider_info_form_resend'
  def resend_log_label = 'Provider-info'

  def resend_log_context
    {
      application_id: @secure_request_form.application_id,
      secure_request_form_id: @secure_request_form.id,
      recipient_id: @secure_request_form.recipient_id,
      recipient_channel: @secure_request_form.recipient_channel
    }
  end
end
