# frozen_string_literal: true

module Admin
  class ApplicationSecureRequestFormBatchRevocationsController < BaseController
    include LoadsNestedApplication

    before_action :load_nested_application

    def create
      revoked_count = 0
      ApplicationRecord.transaction do
        active_batch_requests.each do |secure_request_form|
          secure_request_form.revoke!(actor: current_user, reason: :manual_batch_revocation)
          revoked_count += 1
        end
      end

      redirect_to admin_application_path(@application),
                  notice: t('admin.applications.secure_request_form_batch_revocations.create.success',
                            count: revoked_count)
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved, ActiveRecord::StatementInvalid
      redirect_to admin_application_path(@application),
                  alert: t('admin.applications.secure_request_form_batch_revocations.create.failure')
    end

    private

    def active_batch_requests
      @application
        .secure_request_forms
        .provider_info
        .active
        .where(request_batch_id: batch_revocation_params[:request_batch_id])
    end

    def batch_revocation_params
      params.permit(:request_batch_id)
    end
  end
end
