# frozen_string_literal: true

module Equipment
  class Ordering
    def initialize(actor:)
      @actor = actor
    end

    def call(needs:, items:, purchase_order_attributes: {}, purchase_order_id: nil, expected_po_version: nil, legacy_mapping: false)
      Mutation.authorize!(@actor)
      need_rows = Array(needs).map(&:symbolize_keys)
      item_rows = Array(items).map(&:symbolize_keys)
      validate_selection!(need_rows, item_rows)
      order = nil
      ApplicationRecord.transaction do
        selected_needs = EquipmentNeed.where(id: need_rows.pluck(:id))
        selected_items = EquipmentItem.where(id: item_rows.pluck(:id))
        application_ids = (selected_needs.pluck(:application_id) + selected_items.pluck(:application_id)).uniq
        applications = Mutation.lock_applications!(application_ids)
        applications.each do |application|
          Mutation.eligible!(application)
          if application.equipment_legacy_unmapped? && !legacy_mapping
            raise Conflict, 'Confirm that earlier fulfillment details are being explicitly mapped before ordering.'
          end
        end
        locked_needs = selected_needs.order(:id).lock.to_a
        order = obtain_order!(purchase_order_id, expected_po_version, purchase_order_attributes)
        locked_items = selected_items.order(:id).lock.to_a
        raise Conflict, 'Equipment selection changed. Refresh and select again.' unless locked_needs.size == need_rows.size && locked_items.size == item_rows.size

        consume_needs!(locked_needs, need_rows, order)
        relink_items!(locked_items, item_rows, order)
        Mutation.audit!(order, actor: @actor, action: 'equipment_order_recorded', changes: order.previous_changes.except('updated_at', 'created_at'),
                               application_ids: application_ids, equipment_item_ids: @ordered_item_ids,
                               legacy_mapping: legacy_mapping)
      end
      order
    rescue ActiveRecord::StaleObjectError, ActiveRecord::RecordNotUnique
      raise Conflict, 'Equipment or this vendor/PO number changed. Refresh; choose the existing PO when it is already recorded.'
    end

    private

    def validate_selection!(needs, items)
      raise Conflict, 'Select at least one equipment need or detached device.' if needs.empty? && items.empty?
      raise Conflict, 'Select each row only once.' unless needs.pluck(:id).map(&:to_s).uniq.size == needs.size && items.pluck(:id).map(&:to_s).uniq.size == items.size
    end

    def obtain_order!(id, version, attributes)
      if id.present?
        order = PurchaseOrder.lock.find(id)
        Mutation.version!(order, version)
        order
      else
        values = attributes.symbolize_keys.slice(:vendor_id, :number, :sent_at)
        values[:vendor] = Users::Vendor.where(status: :active).find(values.delete(:vendor_id))
        PurchaseOrder.create!(values)
      end
    end

    def consume_needs!(needs, rows, order)
      @ordered_item_ids = []
      needs.each do |need|
        row = rows.find { |selection| selection[:id].to_s == need.id.to_s }
        Mutation.version!(need, row[:lock_version])
        quantity = Integer(row[:quantity].to_s, 10)
        raise Conflict, 'Order quantities must be positive and no greater than the remaining need.' unless quantity.positive? && quantity <= need.remaining_quantity
        raise Conflict, 'A selected catalog product is no longer available.' if need.product.archived?

        need.update!(remaining_quantity: need.remaining_quantity - quantity)
        quantity.times do
          item = EquipmentItem.create!(application: need.application, product: need.product,
                                       source_evaluation: need.source_evaluation, purchase_order: order)
          @ordered_item_ids << item.id
          Mutation.audit!(item, actor: @actor, action: 'equipment_item_ordered', changes: { purchase_order_id: [nil, order.id], product_id: [nil, item.product_id] },
                                application_ids: [item.application_id], purchase_order_id: order.id, purchase_order_ids: [order.id])
        end
        Mutation.audit!(need, actor: @actor, action: 'equipment_need_consumed', changes: need.previous_changes.slice('remaining_quantity'),
                              application_ids: [need.application_id], purchase_order_id: order.id, purchase_order_ids: [order.id])
      end
    rescue ArgumentError
      raise Conflict, 'Enter whole positive order quantities.'
    end

    def relink_items!(items, rows, order)
      items.each do |item|
        row = rows.find { |selection| selection[:id].to_s == item.id.to_s }
        Mutation.version!(item, row[:lock_version])
        raise Conflict, 'A selected device is no longer awaiting reorder.' unless item.purchase_order_id.nil? && item.shipped_at.nil? && item.withdrawn_at.nil?
        raise Conflict, 'A selected catalog product is no longer available.' if item.product.archived?

        item.update!(purchase_order: order)
        @ordered_item_ids << item.id
        Mutation.audit!(item, actor: @actor, action: 'equipment_item_reordered', changes: item.previous_changes.slice('purchase_order_id'),
                              application_ids: [item.application_id], purchase_order_id: order.id, purchase_order_ids: [order.id])
      end
    end
  end
end
