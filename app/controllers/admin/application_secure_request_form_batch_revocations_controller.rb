# frozen_string_literal: true

module Admin
  class ApplicationSecureRequestFormBatchRevocationsController < BaseController
    include LoadsNestedApplication

    before_action :load_nested_application

    def create
      revoked_count = Applications::PostalRequestClosure.revoke!(application: @application, requests: batch_requests,
                                                                 actor: current_user, reason: :manual_batch_revocation)

      redirect_to admin_application_path(@application),
                  status: :see_other,
                  notice: t('admin.applications.secure_request_form_batch_revocations.create.success',
                            count: revoked_count)
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved, ActiveRecord::StatementInvalid
      redirect_to admin_application_path(@application),
                  status: :see_other,
                  alert: t('admin.applications.secure_request_form_batch_revocations.create.failure')
    end

    private

    def batch_requests
      @application
        .secure_request_forms
        .provider_info
        .where(request_batch_id: batch_revocation_params[:request_batch_id])
    end

    def batch_revocation_params
      params.permit(:request_batch_id)
    end
  end
end
