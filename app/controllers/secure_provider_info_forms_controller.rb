# frozen_string_literal: true

class SecureProviderInfoFormsController < SecurePublicFormController
  layout 'secure_public'

  before_action :set_secure_request_form, only: %i[show update]
  around_action :with_request_locale, only: %i[show update]

  def show
    return render_unavailable unless provider_info_form?
    return render_unavailable if @secure_request_form.revoked?
    return render_submitted if @secure_request_form.submitted?
    return redirect_to new_secure_provider_info_form_resend_path(token: @token) if @secure_request_form.expired?

    assign_constituent_name
  end

  def update
    return render_unavailable unless provider_info_form?
    return render_unavailable if @secure_request_form.revoked?
    return render_submitted if @secure_request_form.submitted?
    return redirect_to new_secure_provider_info_form_resend_path(token: @token) if @secure_request_form.expired?

    result = Applications::SubmitProviderInfo.new(
      application: @secure_request_form.application,
      secure_request_form: @secure_request_form,
      params: provider_info_params
    ).call

    if result.success?
      redirect_to secure_provider_info_form_success_path
    else
      return render_submitted if @secure_request_form.reload.submitted?

      @form_errors = result.data&.fetch(:errors, nil)
      @form_error_message = result.message if @form_errors.blank?
      assign_constituent_name
      render :show, status: :unprocessable_content
    end
  end

  def success; end

  private

  def provider_info_form?
    @secure_request_form.present? && @secure_request_form.kind_provider_info_request?
  end

  def provider_info_params
    params.permit(
      :token,
      :medical_provider_name,
      :medical_provider_email,
      :medical_provider_phone,
      :medical_provider_fax
    )
  end

  def set_secure_request_form
    @token = provider_info_params[:token]
    @secure_request_form = SecureRequestForm.from_public_token(@token)
  end

  def assign_constituent_name
    @constituent_name = public_constituent_name(@secure_request_form.application.user)
    @constituent_name_available = @constituent_name.present?
  end
end
