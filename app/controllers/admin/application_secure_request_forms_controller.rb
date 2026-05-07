# frozen_string_literal: true

module Admin
  class ApplicationSecureRequestFormsController < BaseController
    include LoadsNestedApplication

    before_action :load_nested_application

    def create
      result = Applications::RequestProviderInfo.new(
        application: @application,
        actor: current_user,
        recipient_ids: secure_request_form_params.fetch(:recipient_ids, []),
        channel_overrides: secure_request_form_params[:channel_overrides] || {},
        resend_of: resend_secure_request_form
      ).call

      if result.success?
        redirect_to admin_application_path(@application),
                    notice: t('admin.applications.secure_request_forms.create.success')
      else
        redirect_to admin_application_path(@application),
                    alert: result.message.presence || t('admin.applications.secure_request_forms.create.failure')
      end
    end

    private

    def secure_request_form_params
      # channel_overrides is an open hash; the resolver ignores keys that
      # don't match a known recipient id, so extra keys are inert.
      params.permit(:resend_of_id, recipient_ids: [], channel_overrides: {})
    end

    def resend_secure_request_form
      return if secure_request_form_params[:resend_of_id].blank?

      @resend_secure_request_form ||= @application
                                      .secure_request_forms
                                      .provider_info
                                      .find(secure_request_form_params[:resend_of_id])
    end
  end
end
