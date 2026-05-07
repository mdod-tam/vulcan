# frozen_string_literal: true

module Admin
  class ApplicationSecureRequestFormRevocationsController < BaseController
    include LoadsNestedApplication

    before_action :load_nested_application
    before_action :set_secure_request_form

    def create
      unless @secure_request_form.active?
        redirect_to admin_application_path(@application),
                    alert: t('admin.applications.secure_request_form_revocations.create.not_active')
        return
      end

      @secure_request_form.revoke!(actor: current_user, reason: :manual_revocation)

      redirect_to admin_application_path(@application),
                  notice: t('admin.applications.secure_request_form_revocations.create.success')
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved, ActiveRecord::StatementInvalid
      redirect_to admin_application_path(@application),
                  alert: t('admin.applications.secure_request_form_revocations.create.failure')
    end

    private

    def set_secure_request_form
      @secure_request_form = @application.secure_request_forms.find(params[:secure_request_form_id])
    end
  end
end
