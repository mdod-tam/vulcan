# frozen_string_literal: true

module Admin
  class ApplicationSecureRequestFormRevocationsController < BaseController
    include LoadsNestedApplication

    before_action :load_nested_application
    before_action :set_secure_request_form

    def create
      count = Applications::PostalRequestClosure.revoke!(
        application: @application, requests: @application.secure_request_forms.where(id: @secure_request_form.id),
        actor: current_user, reason: :manual_revocation
      )
      if count.zero?
        redirect_to admin_application_path(@application),
                    status: :see_other,
                    alert: t('admin.applications.secure_request_form_revocations.create.not_active')
        return
      end

      redirect_to admin_application_path(@application),
                  status: :see_other,
                  notice: t('admin.applications.secure_request_form_revocations.create.success')
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved, ActiveRecord::StatementInvalid
      redirect_to admin_application_path(@application),
                  status: :see_other,
                  alert: t('admin.applications.secure_request_form_revocations.create.failure')
    end

    private

    def set_secure_request_form
      @secure_request_form = @application.secure_request_forms.find(params[:secure_request_form_id])
    end
  end
end
