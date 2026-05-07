# frozen_string_literal: true

module Admin
  class ApplicationMedicalProviderSecureRequestFormRevocationsController < BaseController
    include LoadsNestedApplication

    before_action :load_nested_application
    before_action :set_form

    def create
      if @form.active?
        @form.revoke!(actor: current_user, reason: :manual_revocation)
        redirect_to admin_application_path(@application),
                    notice: t('admin.applications.medical_provider_secure_request_form_revocations.create.success')
      else
        redirect_to admin_application_path(@application),
                    alert: t('admin.applications.medical_provider_secure_request_form_revocations.create.not_active')
      end
    rescue StandardError => e
      Rails.logger.error(
        "Cert upload form revocation failed for application #{@application&.id}: #{e.message}"
      )
      redirect_to admin_application_path(@application),
                  alert: t('admin.applications.medical_provider_secure_request_form_revocations.create.failure')
    end

    private

    def set_form
      @form = @application.medical_provider_secure_request_forms.find(
        params[:medical_provider_secure_request_form_id]
      )
    end
  end
end
