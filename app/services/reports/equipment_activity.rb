# frozen_string_literal: true

module Reports
  class EquipmentActivity
    Shipment = Data.define(:item_id, :vendor, :shipped_on, :ordered_on) do
      def days = (shipped_on - ordered_on).to_i
    end
    OpenWork = Data.define(:count, :oldest_days)
    OutstandingOrder = Data.define(:order, :units, :days)
    OutstandingOrders = Data.define(:entries, :total)

    attr_reader :period

    def initialize(period)
      @period = period
    end

    def open_work
      purchasing = Equipment::NavigationSummary.new
      bids = purchasing.bids
      unsent = purchasing.purchase_orders
      awaiting_delivery = Equipment::Queue.new(tab: 'shipped', delivery: 'awaiting').items.where(shipped_at: ..period.now.to_date)
      {
        awaiting_bid: work_awaiting_bid,
        awaiting_award: open_stage(bids.count, bids.oldest_at),
        awaiting_send: open_stage(unsent.count, unsent.oldest_at),
        awaiting_shipment: open_stage(outstanding_vendor_units.distinct.count(:purchase_order_id), outstanding_vendor_units.minimum('purchase_orders.sent_at')),
        awaiting_delivery: open_stage(awaiting_delivery.count, awaiting_delivery.minimum(:shipped_at))
      }
    end

    def shipment_counts
      period.monthly(EquipmentItem.shipped.where(shipped_at: period.dates).group(:shipped_at).count)
    end

    def ship_times
      by_month = shipments.group_by { |shipment| shipment.shipped_on.beginning_of_month }
      period.months.map { |month| average_days(by_month.fetch(month, [])) }
    end

    def average_ship_time
      average_days(shipments)
    end

    def volume_and_speed
      vendor_shipments.map { |vendor, rows| [vendor, rows.size, Percentile.calculate(rows.map(&:days).sort, 0.5)] }
    end

    def vendor_shipping_times
      entries = tracking_entries
      vendor_shipments.map do |vendor, rows|
        days = rows.map(&:days).sort
        lags = rows.filter_map do |shipment|
          entered = entries[shipment.item_id]
          (entered - shipment.shipped_on).to_i if entered && entered >= shipment.shipped_on
        end.sort
        [vendor, days.size, Percentile.calculate(days, 0.5), Percentile.calculate(days, 0.9),
         (Percentile.calculate(lags, 0.5) if lags.any?), lags.size]
      end
    end

    def oldest_outstanding_orders
      units = outstanding_vendor_units.group(:purchase_order_id).count
      entries = PurchaseOrder.where(id: units.keys).order(:sent_at, :id).limit(10).map do |order|
        OutstandingOrder.new(order, units.fetch(order.id), Equipment::WaitTime.days_since(order.sent_at, now: period.now))
      end
      OutstandingOrders.new(entries, units.size)
    end

    def orders_by_vendor
      counts = vendor_units.where(purchase_orders: { sent_at: period.dates })
                           .group('purchase_orders.vendor_name', Arel.sql('equipment_items.shipped_at IS NOT NULL')).count
      groups = counts.group_by { |(vendor, _shipped), _count| vendor.presence&.downcase }
      vendors = groups.values.map do |rows|
        vendor = rows.map { |(name, _shipped), _count| name }.compact_blank.min || 'Vendor not recorded'
        shipped, open = rows.partition { |(_name, recorded), _count| recorded }
        [vendor, shipped.sum(&:last), open.sum(&:last)]
      end
      vendors.sort_by { |vendor, shipped, open| [-open, -shipped, vendor] }
    end

    private

    def work_awaiting_bid
      requests = Equipment::Queue.new.unreserved_requests
      count = requests.sum { |request| request.is_a?(EquipmentNeed) ? request.available_quantity : 1 }
      open_stage(count, requests.filter_map(&:unfulfilled_since).min)
    end

    def open_stage(count, oldest_at)
      OpenWork.new(count, Equipment::WaitTime.days_since(oldest_at, now: period.now))
    end

    def outstanding_vendor_units
      vendor_units.where(shipped_at: nil)
    end

    def vendor_shipments
      @vendor_shipments ||= begin
        groups = shipments.select { |shipment| shipment.vendor.present? }.group_by { |shipment| shipment.vendor.downcase }
        groups.values.map { |rows| [rows.map(&:vendor).min, rows] }.sort_by { |vendor, rows| [-rows.size, vendor] }
      end
    end

    def tracking_entries
      Event.where(auditable_type: 'EquipmentItem', auditable_id: shipments.map(&:item_id), created_at: ..period.now,
                  action: %w[equipment_shipment_recorded equipment_item_corrected])
           .order(:created_at, :id)
           .pluck(:auditable_id, :created_at, Arel.sql("metadata->'changes'->'shipped_at'"))
           .each_with_object({}) do |(item_id, entered_at, change), entries|
        before, after = change.is_a?(Hash) ? change.values_at('old', 'new') : change
        entries[item_id] = entered_at.to_date if before.nil? && after.present?
      end
    end

    def vendor_units
      EquipmentItem.active.direct_vendor.joins(:purchase_order).where(purchase_orders: { sent_at: ..period.now.to_date })
    end

    def shipments
      @shipments ||= vendor_units.where(shipped_at: period.dates)
                                 .pluck(:id, 'purchase_orders.vendor_name', :shipped_at, 'purchase_orders.sent_at')
                                 .map { |row| Shipment.new(*row) }
    end

    def average_days(rows)
      (rows.sum(&:days).to_f / rows.size).round(1) if rows.any?
    end
  end
end
