# frozen_string_literal: true

module Equipment
  class Queue
    attr_reader :needs, :items

    def initialize(tab: 'needs_ordering', product_id: nil, vendor_id: nil)
      @tab = tab
      @needs = EquipmentNeed.remaining.joins(:application).where(applications: { status: :approved, fulfillment_type: :equipment })
      @items = EquipmentItem.active
      @items = case tab
               when 'ordered' then EquipmentItem.ordered
               when 'shipped' then EquipmentItem.shipped
               else EquipmentItem.needs_ordering.joins(:application).where(applications: { status: :approved, fulfillment_type: :equipment })
               end
      @needs = @needs.none unless tab == 'needs_ordering'
      filter_product!(product_id) if product_id.present?
      filter_vendor!(vendor_id) if vendor_id.present?
    end

    def groups
      records = needs.includes(:product, :application).to_a + items.includes(:product, :application, purchase_order: :vendor).to_a
      records.group_by(&:product).sort_by { |product, _rows| [product.manufacturer, product.model_number, product.id] }
    end

    def selection(need_ids: [], item_ids: [], group_product_ids: [])
      raise Conflict, 'Select equipment from Needs Ordering.' unless @tab == 'needs_ordering'

      group_ids = Array(group_product_ids).compact_blank
      selected_needs = needs.where(id: Array(need_ids).compact_blank).or(needs.where(product_id: group_ids))
      selected_items = items.where(id: Array(item_ids).compact_blank).or(items.where(product_id: group_ids))
      result = { needs: selected_needs.includes(:product, :application).order(:id).to_a,
                 items: selected_items.includes(:product, :application).order(:id).to_a }
      explicit_missing = (Array(need_ids).compact_blank.map(&:to_s) - result[:needs].map { |need| need.id.to_s }).any? ||
                         (Array(item_ids).compact_blank.map(&:to_s) - result[:items].map { |item| item.id.to_s }).any?
      group_missing = (group_ids.map(&:to_s) - result.values.flatten.map { |row| row.product_id.to_s }).any?
      raise Conflict, 'A selected row is no longer available. Refresh and review the whole selection.' if explicit_missing || group_missing

      result
    end

    private

    def filter_product!(id)
      @needs = needs.where(product_id: id)
      @items = items.where(product_id: id)
    end

    def filter_vendor!(id)
      if @tab == 'needs_ordering'
        product_ids = Product.joins(:vendors).where(users: { id: id }).select(:id)
        @needs = needs.where(product_id: product_ids)
        @items = items.where(product_id: product_ids)
      else
        @items = items.joins(:purchase_order).where(purchase_orders: { vendor_id: id })
      end
    end
  end
end
