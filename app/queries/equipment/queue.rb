# frozen_string_literal: true

module Equipment
  class Queue
    DispatchGroup = Data.define(:beneficiary, :stock, :items, :oldest_wait_at)
    attr_reader :needs, :items

    def initialize(tab: 'needs_ordering', **filters)
      @tab = tab
      @all_needs = EquipmentNeed.remaining.joins(:application).merge(Application.equipment_procurement_eligible)
      @all_items = case tab
                   when 'ordered' then EquipmentItem.ordered
                   when 'shipped' then shipped_items(filters[:delivery])
                   else EquipmentItem.needs_ordering.joins(:application).merge(Application.equipment_procurement_eligible)
                   end
      @all_needs = @all_needs.none unless tab == 'needs_ordering'
      @needs = @all_needs
      @items = @all_items
      return if filters[:application_id].blank?

      @needs = needs.where(application_id: filters[:application_id])
      @items = items.where(application_id: filters[:application_id])
    end

    def groups
      records = loaded_needs + loaded_items
      records.group_by(&:product).sort_by { |product, _rows| [product.manufacturer, product.model_number, product.id] }
    end

    def unreserved_requests
      available_needs = needs.select(:id, :application_id, :product_id, :remaining_quantity, :unfulfilled_since).includes(bid_group_lines: :bid_group)
                             .select { |need| need.available_quantity.positive? }
      reserved_items = BidGroupLine.reserved.where.not(equipment_item_id: nil).select(:equipment_item_id)
      available_needs + items.where.not(id: reserved_items).select(:id, :application_id, :product_id, :unfulfilled_since).to_a
    end

    def dispatch_groups
      grouped = loaded_items.group_by { |item| [item.application.user_id, item.shipping_snapshot, item.stock?] }
      result = grouped.map do |(_beneficiary_id, _destination, stock), units|
        dates = units.filter_map(&:shipment_wait_started_at).map(&:to_time)
        DispatchGroup.new(beneficiary: units.first.application.user, stock:, items: units, oldest_wait_at: dates.min)
      end
      result.sort_by { |group| [group.oldest_wait_at&.to_f || Float::INFINITY, group.beneficiary.id, group.stock ? 0 : 1, group.items.first.id] }
    end

    def selection(need_ids: [], item_ids: [])
      raise Conflict, 'Select requests in Needs bid number.' unless @tab == 'needs_ordering'

      result = { needs: @all_needs.where(id: need_ids).includes(:product, application: :user).order(:id).to_a,
                 items: @all_items.where(id: item_ids).includes(:product, application: :user).order(:id).to_a }
      unless Array(need_ids).map(&:to_s).sort == result[:needs].map { |need| need.id.to_s }.sort && Array(item_ids).map(&:to_s).sort == result[:items].map { |item|
        item.id.to_s
      }.sort
        raise Conflict, 'A selected request is stale or unavailable. Review the whole selection.'
      end

      result
    end

    private

    def shipped_items(delivery)
      items = EquipmentItem.shipped
      delivery == 'awaiting' ? items.where(delivered_on: nil) : items
    end

    def loaded_needs
      @loaded_needs ||= needs.includes(:product, { application: :user }, bid_group_lines: :bid_group).to_a
    end

    def loaded_items
      @loaded_items ||= items.includes(:product, { application: :user }, :purchase_order, :acquisition_bid_group_line,
                                       bid_group_lines: :bid_group).to_a
    end
  end
end
