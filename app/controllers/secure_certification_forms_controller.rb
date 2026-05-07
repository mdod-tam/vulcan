# frozen_string_literal: true

class SecureCertificationFormsController < SecurePublicFormController
  layout 'secure_public'

  before_action :set_secure_request_form, only: %i[show update]
  around_action :with_request_locale, only: %i[show update]

  def show
    return render_submitted if certification_request_form? && @secure_request_form.submitted?
    return render_unavailable unless certification_form_available_for_display?
    return redirect_to new_secure_certification_form_resend_path(token: @token) if @secure_request_form.expired?

    assign_display_context
  end

  def update
    return render_unavailable unless certification_form_available_for_update?
    return render_submitted if @secure_request_form.submitted?
    return redirect_to new_secure_certification_form_resend_path(token: @token) if @secure_request_form.expired?

    result = Applications::SubmitCertificationUpload.new(
      application: @secure_request_form.application,
      medical_provider_secure_request_form: @secure_request_form,
      file: certification_form_params[:file]
    ).call

    if result.success?
      redirect_to secure_certification_form_success_path
    else
      return render_submitted if @secure_request_form.reload.submitted?

      @form_errors = result.data&.fetch(:errors, nil)
      @form_error_message = result.message if @form_errors.blank?
      assign_display_context
      render :show, status: :unprocessable_content
    end
  end

  def success; end

  private

  def certification_form_available_for_display?
    certification_request_form? && !@secure_request_form.revoked? && !@secure_request_form.submitted?
  end

  def certification_form_available_for_update?
    return false unless certification_request_form?
    return false if @secure_request_form.revoked?

    true
  end

  def certification_request_form?
    @secure_request_form.present? && @secure_request_form.kind_certification_upload?
  end

  def assign_display_context
    @constituent_display_name = public_constituent_name(
      @secure_request_form.application.user,
      fallback: t('secure_certification_forms.show.constituent_unknown')
    )
    @application_id = @secure_request_form.application_id
  end

  def set_secure_request_form
    @token = certification_form_params[:token]
    @secure_request_form = MedicalProviderSecureRequestForm.from_public_token(@token)
  end

  def certification_form_params
    params.permit(:token, :file)
  end

  def locale_recipient_for_request
    @secure_request_form&.application&.user
  end
end
