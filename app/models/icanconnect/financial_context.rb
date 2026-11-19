# frozen_string_literal: true

module Icanconnect
  module FinancialContext
    def self.lock!(records)
      application_ids = records.filter_map { |record| record.try(:application_id) }
      order_ids = records.filter_map { |record| record.is_a?(PurchaseOrder) ? record.id : record.try(:purchase_order_id) }
      application_ids += EquipmentItem.where(purchase_order_id: order_ids).pluck(:application_id).compact
      Application.where(id: application_ids).order(:id).lock.load
      PurchaseOrder.where(id: order_ids).order(:id).lock.load
      EquipmentItem.where(purchase_order_id: order_ids).order(:id).lock.load
    end
  end
end
