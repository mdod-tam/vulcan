# frozen_string_literal: true

module Admin
  module IcanconnectHelper
    def icc_service_funding_options(record)
      options = [%w[MAT mat]]
      options << %w[iCanConnect icanconnect] if record.funding_source == 'icanconnect' || ::Icanconnect::Setting.active?(on: record.service_source_on)
      options
    end

    def icc_cost_label(record)
      case record
      when EquipmentItem then "Device ##{record.id}"
      when PurchaseOrder then "PO #{record.number}"
      when ApplicationServiceExpense then "Service bill ##{record.id}"
      else "#{record.class.model_name.human} ##{record.id}"
      end
    end

    def icc_financial_field_label(field)
      {
        unit_cost: 'Price paid for this device', delivered_on: 'Date received by the recipient', installed_on: 'Installation date',
        funding_source: 'Funding', vendor_name: 'Supplier or provider name', invoice_on: 'Invoice date',
        vendor_invoice_number: 'Invoice or timesheet reference', equipment_item_id: 'Device', other_cost: 'Other charges',
        other_cost_category: 'What the other charges cover', mileage: 'Mileage (miles)', mileage_rate: 'Cost per mile ($)'
      }.fetch(field, field.to_s.humanize)
    end

    def icc_training_details(session)
      details = ["Trainer: #{session.trainer.full_name}", "Product: #{session.product_trained_on&.name}", "Duration: #{session.duration_hours} hours"]
      details << "Billed: #{session.billable_hours} hours at #{number_to_currency(session.hourly_rate)}/hour" if session.hourly_rate && session.billable_hours
      if session.mileage
        rate = session.mileage_rate ? " at #{number_to_currency(session.mileage_rate, precision: 3)}/mile" : ''
        details << "Mileage: #{session.mileage} miles#{rate}"
      end
      session.equipment_items.each do |item|
        details << "Device ##{item.id}: #{item.product.name} (#{equipment_funding_label(item)})"
      end
      details
    end

    def icc_source_path(record)
      case record
      when EquipmentItem then edit_admin_equipment_item_path(record)
      when PurchaseOrder then admin_purchase_order_path(record)
      when Evaluation then evaluators_evaluation_path(record)
      when TrainingSession then trainers_training_session_path(record)
      when ApplicationServiceExpense then admin_application_path(record.application)
      end
    end

    def icc_source_label(record)
      case record
      when EquipmentItem then 'View device details'
      when PurchaseOrder then 'View purchase order details'
      when Evaluation then 'View evaluation details'
      when TrainingSession then 'View training details'
      end
    end
  end
end
