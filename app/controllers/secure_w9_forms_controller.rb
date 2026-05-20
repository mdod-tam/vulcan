# frozen_string_literal: true

class SecureW9FormsController < SecurePublicFormController
  layout 'secure_public'

  before_action :set_secure_request_form, only: %i[show update]
  around_action :with_request_locale, only: %i[show update]

  def show
    return render_submitted if w9_request_form? && @secure_request_form.submitted?
    return render_unavailable unless w9_form_available_for_display?

    redirect_to new_secure_w9_form_resend_path(token: @token) if @secure_request_form.expired?
  end

  def update
    return render_unavailable unless w9_form_available_for_update?
    return render_submitted if @secure_request_form.submitted?
    return redirect_to new_secure_w9_form_resend_path(token: @token) if @secure_request_form.expired?

    result = Vendors::SubmitW9Resubmission.new(
      vendor: @secure_request_form.vendor,
      vendor_secure_request_form: @secure_request_form,
      file: uploaded_file
    ).call

    if result.success?
      redirect_to secure_w9_form_success_path
    else
      return render_submitted if @secure_request_form.reload.submitted?

      @form_errors = result.data&.fetch(:errors, nil)
      @form_error_message = result.message if @form_errors.blank?
      render :show, status: :unprocessable_content
    end
  end

  def success; end

  private

  def w9_form_available_for_display?
    w9_request_form? && !@secure_request_form.revoked? && !@secure_request_form.submitted?
  end

  def w9_form_available_for_update?
    return false unless w9_request_form?
    return false if @secure_request_form.revoked?

    true
  end

  def w9_request_form?
    @secure_request_form.present? && @secure_request_form.kind_w9_upload?
  end

  def set_secure_request_form
    @token = token_param
    @secure_request_form = VendorSecureRequestForm.from_public_token(@token)
  end

  def token_param
    params[:token]
  end

  def uploaded_file
    params[:file]
  end

  def locale_recipient_for_request
    @secure_request_form&.vendor
  end
end
