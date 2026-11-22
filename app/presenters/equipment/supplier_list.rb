# frozen_string_literal: true

module Equipment
  class SupplierList
    Row = Data.define(:model, :quantity, :recipient, :setup, :address, :completed)
    SHIP_TO_HEADINGS = ['Product model', 'Quantity', 'Recipient', 'Shipping address'].freeze

    attr_reader :purchase_order

    def initialize(purchase_order: nil, dispatch_items: nil)
      raise ArgumentError, 'Provide a PO or the internal dispatch units' unless purchase_order.present? != dispatch_items.present?

      @purchase_order = purchase_order
      @dispatch_items = dispatch_items
    end

    def rows
      @rows ||= build_rows
    end

    def headings
      purchase_order ? SHIP_TO_HEADINGS : SHIP_TO_HEADINGS + ['Disability setup', 'Shipment']
    end

    def table_values(row)
      values = ship_to_values(row)
      return values if purchase_order

      values + [row.setup, row.completed ? 'Already shipped' : 'Pending']
    end

    def references
      return unless purchase_order

      purchase_order.bid_groups.order(:number).pluck(:number).join(', ')
    end

    def summary
      bids = references.presence
      prefix = purchase_order ? ("Bids #{bids}" if bids) : 'Internal dispatch'
      applications = items.filter_map(&:application_id).uniq.size
      destinations = rows.map(&:address).uniq.size
      [prefix, "#{items.size} #{'item'.pluralize(items.size)}", "#{applications} #{'application'.pluralize(applications)}",
       "#{destinations} #{'shipping address'.pluralize(destinations)}"].compact.join(' · ')
    end

    def plain_text
      return supplier_plain_text if purchase_order

      ([summary, headings.join("\t")] + rows.map { |row| table_values(row).join("\t") }).join("\n")
    end

    private

    def supplier_plain_text
      grouped = rows.group_by { |row| [row.model, row.recipient, row.address] }
      blocks = grouped.map do |(model, recipient, address), lines|
        [model, "Quantity: #{lines.sum(&:quantity)}", "Ship to: #{recipient}", *address].join("\n")
      end
      (["Purchase order #{purchase_order.number}"] + blocks).join("\n\n")
    end

    def ship_to_values(row)
      [row.model, row.quantity, row.recipient, row.address.join(' · ')]
    end

    def build_rows
      grouped = items.group_by { |item| grouping_key(item) }
      result = grouped.map do |(_product_id, _beneficiary_id, recipient, setup, address, completed), units|
        model = units.first.product.catalog_label
        label = Product::PROGRAM_GROUPS.fetch(setup, setup.presence || 'Setup needed') unless purchase_order
        Row.new(model:, quantity: units.size, recipient:, setup: label, address:, completed:)
      end
      result.sort_by { |row| [row.recipient, row.address, row.model, row.setup.to_s, row.completed ? 1 : 0] }
    end

    def grouping_key(item)
      stock = stock_supplier?
      recipient = stock ? 'Program stock' : item.application.user.full_name
      setup = item.disability_setup_group unless purchase_order
      address = address_for(stock ? purchase_order : item)
      completed = item.shipped_at.present? unless purchase_order
      [item.product_id, stock ? nil : item.application.user_id, recipient, setup, address, completed]
    end

    def stock_supplier?
      purchase_order&.program_stock?
    end

    def items
      @items ||= if @dispatch_items
                   @dispatch_items.to_a.reject(&:withdrawn_at?)
                 else
                   scope = purchase_order.equipment_items.active.includes(:product).order(:id)
                   scope = scope.includes(application: :user) unless stock_supplier?
                   scope.to_a
                 end
    end

    def address_for(record)
      lines = [record.shipping_care_of.presence && "Care of #{record.shipping_care_of}",
               record.shipping_address_1, record.shipping_address_2,
               [record.shipping_city, record.shipping_state, record.shipping_zip_code].compact_blank.join(', ')]
      lines.compact_blank.presence || ['Shipping address needed']
    end
  end
end
