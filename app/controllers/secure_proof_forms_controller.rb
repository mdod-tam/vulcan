# frozen_string_literal: true

class SecureProofFormsController < SecurePublicFormController
  layout 'secure_public'

  before_action :set_secure_request_form, only: %i[show update]
  around_action :with_request_locale, only: %i[show update]

  def show
    return render_submitted if proof_request_form? && @secure_request_form.submitted?
    return render_unavailable unless proof_form_available_for_display?
    return redirect_to new_secure_proof_form_resend_path(token: @token) if @secure_request_form.expired?

    assign_proof_type
  end

  def update
    return render_unavailable unless proof_form_available_for_update?
    return render_submitted if @secure_request_form.submitted?
    return redirect_to new_secure_proof_form_resend_path(token: @token) if @secure_request_form.expired?

    result = Applications::SubmitProofResubmission.new(
      application: @secure_request_form.application,
      secure_request_form: @secure_request_form,
      file: proof_form_params[:file]
    ).call

    if result.success?
      redirect_to secure_proof_form_success_path
    else
      return render_submitted if @secure_request_form.reload.submitted?

      @form_errors = result.data&.fetch(:errors, nil)
      @form_error_message = result.message if @form_errors.blank?
      assign_proof_type
      render :show, status: :unprocessable_content
    end
  end

  def success; end

  private

  def proof_form_available_for_display?
    proof_request_form? && !@secure_request_form.revoked? && !@secure_request_form.submitted?
  end

  def proof_form_available_for_update?
    return false unless proof_request_form?
    return false if @secure_request_form.revoked?

    true
  end

  def proof_request_form?
    @secure_request_form.present? && @secure_request_form.kind.in?(Applications::SubmitProofResubmission::KIND_TO_PROOF_TYPE.keys)
  end

  def assign_proof_type
    proof_type = Applications::SubmitProofResubmission::KIND_TO_PROOF_TYPE.fetch(@secure_request_form.kind)
    @proof_type_label = t("secure_proof_forms.proof_types.#{proof_type}")
  end

  def set_secure_request_form
    @token = proof_form_params[:token]
    @secure_request_form = SecureRequestForm.from_public_token(@token)
  end

  def proof_form_params
    params.permit(:token, :file)
  end
end
