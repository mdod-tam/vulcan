# frozen_string_literal: true

module Admin
  class ApplicationSecureRequestFormsController < BaseController
    include LoadsNestedApplication

    before_action :load_nested_application

    def create
      result = Applications::RequestProviderInfo.new(
        application: @application,
        actor: current_user,
        recipient_ids: recipient_ids_param,
        channel_overrides: channel_overrides_param,
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

    def recipient_ids_param
      Array(params[:recipient_ids])
    end

    def channel_overrides_param
      raw_overrides = params[:channel_overrides]
      return {} if raw_overrides.blank?

      # channel_overrides is an open hash; the resolver ignores keys that
      # don't match a known recipient id, so extra keys are inert.
      raw_overrides.respond_to?(:to_unsafe_h) ? raw_overrides.to_unsafe_h : raw_overrides.to_h
    end

    def resend_secure_request_form
      return if params[:resend_of_id].blank?

      @resend_secure_request_form ||= @application
                                      .secure_request_forms
                                      .provider_info
                                      .find(params[:resend_of_id])
    end
  end
end
