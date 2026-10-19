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

    def render_equipment_correction_review
      respond_to do |format|
        format.html { render :edit }
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            'equipment-correction', html: render_to_string(:edit, formats: [:html], layout: false)
          )
        end
      end
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
