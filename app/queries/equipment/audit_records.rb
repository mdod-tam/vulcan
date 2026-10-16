# frozen_string_literal: true

module Equipment
  class AuditRecords
    def self.for(events)
      ids = { 'product_id' => [], 'purchase_order_id' => [], 'vendor_id' => [] }
      events.grep(Event).select { |event| event.action.start_with?('equipment_') }.each do |event|
        event.field_change_pairs.each do |field, values|
          if field == 'equipment_needs'
            values.compact.flatten.each { |row| ids['product_id'] << row['product_id'] }
          elsif ids.key?(field)
            ids[field].concat(values)
          end
        end
      end
      {
        products: Product.where(id: ids['product_id'].compact.uniq).to_a,
        purchase_orders: PurchaseOrder.includes(:vendor).where(id: ids['purchase_order_id'].compact.uniq).to_a,
        vendors: Users::Vendor.where(id: ids['vendor_id'].compact.uniq).to_a
      }
    end
  end
end
