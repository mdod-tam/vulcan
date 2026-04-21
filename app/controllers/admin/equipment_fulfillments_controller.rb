# frozen_string_literal: true

module Admin
  class EquipmentFulfillmentsController < ApplicationController
    before_action :require_admin!

    def update
      @application = Application.find(params[:application_id])
      permitted_params = fulfillment_params

      # Use the explicit APIs based on what was submitted
      if permitted_params[:equipment_bids_sent_at].present?
        @application.mark_equipment_bids_sent!(
          date: permitted_params[:equipment_bids_sent_at],
          actor: current_user
        )
      end

      if permitted_params[:equipment_po_sent_at].present?
        @application.mark_equipment_po_sent!(
          date: permitted_params[:equipment_po_sent_at],
          actor: current_user
        )
      end

      redirect_back_or_to admin_application_path(@application),
                          notice: 'Fulfillment dates updated successfully.'
    end

    private

    def fulfillment_params
      params.expect(application: %i[equipment_bids_sent_at equipment_po_sent_at])
    end

    def require_admin!
      redirect_to root_path, alert: t('shared.unauthorized') unless current_user&.admin?
    end
  end
end
