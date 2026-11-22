# frozen_string_literal: true

module Equipment
  class PurchaseCosts
    ORDER_FIELDS = %i[vendor_name].freeze

    def self.update!(order:, rows:, expected_version:, actor:, order_attributes: {})
      Mutation.authorize!(actor)
      order.transaction do
        Icanconnect::FinancialContext.lock!([order])
        order.lock!
        Mutation.version!(order, expected_version)
        items = order.equipment_items.order(:id).lock.to_a
        submitted = Array(rows).map { |row| row.to_h.with_indifferent_access }
        raise Conflict, 'PO membership changed. Review the actual unit costs again.' unless submitted.map { |row| row[:id].to_s }.sort == items.map { |item|
          item.id.to_s
        }.sort

        order.assign_attributes(order_attributes.to_h.symbolize_keys.slice(*ORDER_FIELDS))
        if order.changed?
          order.save!
          Mutation.audit!(order, actor: actor, action: 'equipment_supplier_recorded', changes: order.saved_changes.slice(*ORDER_FIELDS.map(&:to_s)),
                                 purchase_order_ids: [order.id], equipment_item_ids: items.pluck(:id), application_ids: items.pluck(:application_id).compact.uniq)
        end
        items.each do |item|
          row = submitted.find { |entry| entry[:id].to_s == item.id.to_s }
          Mutation.version!(item, row[:lock_version])
          next if item.icc_financial_evidence_locked? && !row.key?(:unit_cost)

          save_unit_cost!(item: item, amount: row[:unit_cost], actor: actor)
        end
      end
      order
    end

    def self.update_unit!(item:, amount:, expected_version:, actor:)
      Mutation.authorize!(actor)
      item.transaction do
        Icanconnect::FinancialContext.lock!([item])
        item.lock!
        Mutation.version!(item, expected_version)
        save_unit_cost!(item: item, amount: amount, actor: actor)
      end
      item
    end

    def self.parse_unit_cost!(amount)
      return if amount.blank?

      MoneyInput.parse(amount) || raise(Conflict, 'Enter a valid price per device in dollars and cents, or leave it blank.')
    end

    def self.save_unit_cost!(item:, amount:, actor:)
      previous = item.unit_cost
      item.update!(unit_cost: parse_unit_cost!(amount))
      return if previous == item.unit_cost

      Mutation.audit!(item, actor: actor, action: 'equipment_purchase_cost_recorded', changes: { unit_cost: [previous, item.unit_cost] },
                            purchase_order_ids: [item.purchase_order_id].compact, equipment_item_ids: [item.id], application_ids: [item.application_id].compact)
    end
    private_class_method :save_unit_cost!
  end
end
