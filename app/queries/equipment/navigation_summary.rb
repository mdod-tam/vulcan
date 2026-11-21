# frozen_string_literal: true

module Equipment
  class NavigationSummary
    Metric = Data.define(:count, :oldest_at, :unknown_dates, :oldest_application, :oldest_record, :products, :additional_constituents)

    def requests
      @requests ||= begin
        queue = Queue.new
        needs = queue.needs.select(:id, :application_id, :product_id, :remaining_quantity, :unfulfilled_since).includes(bid_group_lines: :bid_group)
                     .select { |need| need.available_quantity.positive? }
        reserved_items = BidGroupLine.reserved.where.not(equipment_item_id: nil).select(:equipment_item_id)
        items = queue.items.where.not(id: reserved_items).select(:id, :application_id, :product_id, :unfulfilled_since).to_a
        fulfillment_metric(needs + items, &:unfulfilled_since)
      end
    end

    def shipments
      @shipments ||= begin
        items = EquipmentItem.ordered.select(:id, :application_id, :product_id, :fulfillment_source, :purchase_order_id, :stock_allocated_at).to_a
        ActiveRecord::Associations::Preloader.new(records: items.select(&:direct_vendor?), associations: :purchase_order,
                                                  scope: PurchaseOrder.select(:id, :sent_at)).call
        fulfillment_metric(items, &:shipment_wait_started_at)
      end
    end

    def bids
      @bids ||= begin
        dates = BidGroup.awaiting_award.pluck(:id, :created_at).to_h
        id = oldest_record_id(dates)
        if id
          bid = BidGroup.find(id)
          purchasing_metric(dates.values, record: bid, members: bid_members(bid))
        else
          metric(dates.values)
        end
      end
    end

    def purchase_orders
      @purchase_orders ||= begin
        rows = EquipmentItem.active.where(purchase_order_id: PurchaseOrder.ready_to_send.select(:id)).pluck(:purchase_order_id, :po_assigned_at)
        dates = rows.group_by(&:first).transform_values do |members|
          clocks = members.map(&:last)
          clocks.min unless clocks.include?(nil)
        end
        id = oldest_record_id(dates)
        if id
          order = PurchaseOrder.find(id)
          members = order.equipment_items.active.order(:po_assigned_at, :id).pluck(:application_id, :product_id)
          purchasing_metric(dates.values, record: order, members:)
        else
          metric(dates.values)
        end
      end
    end

    def available_counts
      @available_counts ||= EquipmentItem.available_stock.group(:product_id).count
    end

    def reserved_counts
      @reserved_counts ||= EquipmentItem.reserved_stock.group(:product_id).count
    end

    def incoming_counts
      @incoming_counts ||= EquipmentItem.incoming_stock.group(:product_id).count
    end

    def stock_counts
      @stock_counts ||= { available: available_counts.values.sum, reserved: reserved_counts.values.sum, incoming: incoming_counts.values.sum }
    end

    private

    def fulfillment_metric(records, &)
      dates = records.index_with(&)
      oldest = dates.compact.min_by do |record, date|
        [date.to_time, record.application_id]
      end&.first
      return metric(dates.values) unless oldest

      ActiveRecord::Associations::Preloader.new(records: [oldest], associations: [:product, { application: :user }]).call
      metric(dates.values, oldest_record: oldest, oldest_application: oldest.application, products: [oldest.product])
    end

    def oldest_record_id(dates)
      dates.compact.min_by { |id, date| [date.to_time, id] }&.first
    end

    def bid_members(bid)
      lines = bid.active_lines.order(:created_at, :id).to_a
      need_lines = lines.select(&:equipment_need_id?)
      item_lines = lines.select(&:equipment_item_id?)
      ActiveRecord::Associations::Preloader.new(records: need_lines, associations: :equipment_need,
                                                scope: EquipmentNeed.select(:id, :application_id)).call
      ActiveRecord::Associations::Preloader.new(records: item_lines, associations: :equipment_item,
                                                scope: EquipmentItem.select(:id, :application_id)).call
      lines.map { |line| [(line.equipment_need || line.equipment_item)&.application_id, line.product_id] }
    end

    def purchasing_metric(dates, record:, members:)
      application_ids = members.filter_map(&:first).uniq
      application = Application.includes(:user).find(application_ids.first) if application_ids.any?
      constituent_ids = Application.where(id: application_ids).distinct.pluck(:user_id)
      product_ids = members.select { |application_id, _product_id| application_id == application&.id }.map(&:last).uniq
      products = Product.where(id: product_ids).index_by(&:id)
      metric(dates, oldest_record: record, oldest_application: application, products: product_ids.map { |id| products.fetch(id) },
                    additional_constituents: [constituent_ids.size - 1, 0].max)
    end

    def metric(dates, oldest_record: nil, oldest_application: nil, products: [], additional_constituents: 0)
      Metric.new(count: dates.size, oldest_at: dates.compact.map(&:to_time).min, unknown_dates: dates.count(nil),
                 oldest_record:, oldest_application:, products:, additional_constituents:)
    end
  end
end
