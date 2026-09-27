# frozen_string_literal: true

class SecureW9FormResendsController < SecureRequestResendController
  private

  def request_form_class = VendorSecureRequestForm
  def request_form_kind_matches? = @secure_request_form.kind_w9_upload?

  def request_replacement_link
    Vendors::RequestW9Resubmission.new(
      vendor: @secure_request_form.vendor,
      actor: @secure_request_form.requested_by || User.system_user,
      resend_of: @secure_request_form,
      public_recovery: true
    ).call
  end

  def form_path = secure_w9_form_path(token: @token)
  def sent_path(**) = secure_w9_form_resend_sent_path(**)
  def rate_limit_key = 'secure_w9_form_resend'
  def resend_log_label = 'W9 resubmission'

  def resend_log_context
    { vendor_id: @secure_request_form.vendor_id, vendor_secure_request_form_id: @secure_request_form.id }
  end

  def locale_recipient_for_request
    @secure_request_form&.vendor
  end
end
