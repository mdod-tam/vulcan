# frozen_string_literal: true

module Admin
  module EquipmentFormHandling
    extend ActiveSupport::Concern

    private

    def equipment_form_errors(exception)
      exception.is_a?(ActiveRecord::RecordInvalid) ? exception.record.errors.full_messages : [exception.message]
    end

    def equipment_snapshot(record, fields)
      record.attributes.slice(*fields)
    end

    def preview_equipment_correction(record, attributes:, fields:)
      @previous_values = equipment_snapshot(record, fields)
      record.assign_attributes(attributes)
      @reviewing = true
      @impact_token = Equipment::Correction.impact_token(record: record, attributes: attributes, extra: equipment_impact_extra)
    end

    def restore_equipment_correction(record, attributes:, fields:)
      record.reload
      @previous_values = equipment_snapshot(record, fields)
      record.assign_attributes(attributes)
      yield record if block_given?
      record.valid?
      @reviewing = params[:reviewing] == '1'
      @impact_token = params[:impact_token]
    end
  end
end
