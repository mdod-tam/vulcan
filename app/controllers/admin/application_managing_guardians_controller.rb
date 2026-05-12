# frozen_string_literal: true

module Admin
  class ApplicationManagingGuardiansController < BaseController
    include LoadsNestedApplication

    before_action :load_nested_application

    # Secure provider-info requests need one authoritative guardian recipient
    # before issuing links for dependents with multiple guardian relationships.
    def update
      guardian_id = managing_guardian_params[:managing_guardian_id].presence
      unless guardian_id
        redirect_to admin_application_path(@application),
                    alert: t('admin.applications.managing_guardians.update.failure')
        return
      end

      relationship = GuardianRelationship.find_by(
        dependent_id: @application.user_id,
        guardian_id: guardian_id
      )

      if relationship.present?
        @application.update!(managing_guardian_id: relationship.guardian_id)
        redirect_to admin_application_path(@application),
                    notice: t('admin.applications.managing_guardians.update.success')
      else
        redirect_to admin_application_path(@application),
                    alert: t('admin.applications.managing_guardians.update.failure')
      end
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved
      redirect_to admin_application_path(@application),
                  alert: t('admin.applications.managing_guardians.update.failure')
    end

    private

    def managing_guardian_params
      params.permit(:managing_guardian_id)
    end
  end
end
