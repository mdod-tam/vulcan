# frozen_string_literal: true

module Admin
  # Equipment fulfillment for an equipment application: the bids-sent and PO-sent dates and the
  # order's tracking number, edited together from the admin application page.
  class EquipmentFulfillmentsController < ApplicationController
    before_action :require_admin!

    DATE_FIELDS = %i[equipment_bids_sent_at equipment_po_sent_at].freeze

    def update
      @application = Application.find(params[:application_id])
      permitted_params = fulfillment_params

      alert = submission_problem(permitted_params)
      return redirect_back_or_to admin_application_path(@application), alert: alert if alert

      ActiveRecord::Base.transaction do
        @application.mark_equipment_bids_sent!(date: permitted_params[:equipment_bids_sent_at], actor: current_user) if permitted_params[:equipment_bids_sent_at].present?
        @application.mark_equipment_po_sent!(date: permitted_params[:equipment_po_sent_at], actor: current_user) if permitted_params[:equipment_po_sent_at].present?
        @application.record_equipment_tracking_number!(number: permitted_params[:equipment_tracking_number], actor: current_user)
      end

      redirect_back_or_to admin_application_path(@application), notice: 'Equipment fulfillment updated.'
    rescue ActiveRecord::RecordInvalid => e
      redirect_back_or_to admin_application_path(@application), alert: e.record.errors.full_messages.to_sentence
    end

    private

    def fulfillment_params
      params.expect(application: [*DATE_FIELDS, :equipment_tracking_number])
    end

    def submission_problem(permitted_params)
      return 'Equipment fulfillment applies only to equipment applications.' unless @application.equipment_fulfillment?
      return 'Enter dates as MM/DD/YYYY.' if DATE_FIELDS.any? { |field| DateInputNormalizer.invalid?(permitted_params[field]) }
      return if (DATE_FIELDS + [:equipment_tracking_number]).any? { |field| permitted_params[field].present? }

      'Provide a fulfillment date or a tracking number.'
    end

    def require_admin!
      redirect_to root_path, alert: t('shared.unauthorized') unless current_user&.admin?
    end
  end
end
