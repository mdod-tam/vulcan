# frozen_string_literal: true

class SecureW9FormsController < SecureRequestFormController
  private

  def request_form_class = VendorSecureRequestForm
  def request_form_kind_matches? = @secure_request_form.kind_w9_upload?

  def submit_request_form
    Vendors::SubmitW9Resubmission.new(
      vendor: @secure_request_form.vendor,
      vendor_secure_request_form: @secure_request_form,
      file: params[:file]
    ).call
  end

  def form_path = secure_w9_form_path(token: @token)
  def resend_path = new_secure_w9_form_resend_path(token: @token)
  def success_redirect_path = secure_w9_form_success_path

  def locale_recipient_for_request
    @secure_request_form&.vendor
  end
end
