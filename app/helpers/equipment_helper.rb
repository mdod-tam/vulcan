# frozen_string_literal: true

module EquipmentHelper
  TRACKING_DESTINATIONS = {
    'ups' => ['https://www.ups.com/track', 'tracknum', { 'loc' => 'en_US' }],
    'fedex' => ['https://www.fedex.com/apps/fedextrack/', 'tracknumbers', {}],
    'usps' => ['https://tools.usps.com/go/TrackConfirmAction', 'tLabels', {}]
  }.freeze
  EQUIPMENT_AUDIT_FIELDS = (Equipment::Correction::EDITABLE_ITEM_FIELDS + Equipment::Correction::PO_FIELDS +
    %w[equipment_needs remaining_quantity withdrawn_at]).freeze

  def equipment_catalog_label(product)
    [product&.manufacturer, product&.name, product&.model_number].compact_blank.uniq.join(' / ')
  end

  def equipment_catalog_options(products)
    products.map { |product| [equipment_catalog_label(product), product.id] }
  end

  def equipment_tracking_url(item)
    destination = TRACKING_DESTINATIONS[item.carrier]
    return unless destination && item.tracking_number.present?

    base, parameter, constants = destination
    "#{base}?#{URI.encode_www_form(constants.merge(parameter => item.tracking_number))}"
  end

  def equipment_tracking_link(item)
    url = equipment_tracking_url(item)
    return unless url

    link_to 'Track package', url, target: '_blank', rel: 'noopener noreferrer', referrerpolicy: 'no-referrer',
                                  aria: { label: "Track package with #{EquipmentItem::CARRIERS.fetch(item.carrier)} (opens in a new tab)" },
                                  class: 'text-indigo-700 underline'
  end

  def equipment_return_path(context)
    admin_equipment_index_path(Equipment::RequestParameters.return_context(context))
  end

  def equipment_queue_badge(item)
    labels = { 'needs_ordering' => 'Previously ordered device awaiting reorder', 'ordered' => 'Ordered',
               'shipped' => 'Shipped', 'withdrawn' => 'Withdrawn' }
    state = item.queue_status
    tag.span(labels.fetch(state), class: "rounded px-2 py-1 text-sm font-medium #{badge_class_for(:equipment, state)}")
  end

  def equipment_impact_value(field, value, products: [], purchase_orders: [], vendors: [], new_purchase_order: nil)
    return equipment_needs_value(value, products: products) if field == 'equipment_needs'
    return equipment_new_order_value(new_purchase_order, vendors) if field == 'purchase_order_id' && new_purchase_order
    return 'Not recorded' if value.blank?

    return EquipmentItem::CARRIERS.fetch(value, value) if field == 'carrier'
    return equipment_date_value(field, value) if field.in?(%w[shipped_at sent_at withdrawn_at])

    records = { 'product_id' => products, 'purchase_order_id' => purchase_orders, 'vendor_id' => vendors }
    return value unless records.key?(field)

    equipment_record_value(field, records[field].find { |candidate| candidate.id.to_s == value.to_s })
  end

  def equipment_field_label(field)
    model = if field.in?(Equipment::Correction::PO_FIELDS)
              PurchaseOrder
            elsif field == 'remaining_quantity'
              EquipmentNeed
            elsif field == 'equipment_needs'
              Application
            else
              EquipmentItem
            end
    model.human_attribute_name(field)
  end

  def equipment_impact_fields(record, previous_values, fields:, new_purchase_order: nil)
    fields.select do |field|
      (field == 'purchase_order_id' && new_purchase_order) || previous_values[field] != record.public_send(field) ||
        record.try(:"rejected_#{field}_input").present?
    end
  end

  def equipment_audit_changes(event, records:)
    changes = event.field_change_pairs.filter_map do |field, (before, after)|
      next unless EQUIPMENT_AUDIT_FIELDS.include?(field)

      safe_join(["#{equipment_field_label(field)}: ", equipment_impact_value(field, before, **records), ' → ',
                 equipment_impact_value(field, after, **records)])
    end
    safe_join(changes, tag.br)
  end

  def equipment_audit_details(event, records:)
    details = [equipment_audit_changes(event, records: records), event.metadata['reason']]
    acknowledgment = event.field_change_pairs.fetch('serial_duplicate_reason', []).last
    details << "Serial warning acknowledgment: #{acknowledgment}" if acknowledgment.present?
    safe_join(details.compact_blank, tag.br)
  end

  private

  def equipment_date_value(field, value)
    value = parse_activity_time(value) || value if field == 'withdrawn_at'
    accessible_date_value(value) || 'Not recorded'
  end

  def equipment_new_order_value(order, vendors)
    vendor = vendors.find { |candidate| candidate.id == order.vendor_id }
    "#{vendor&.business_name || 'Vendor not selected'} / #{order.number.presence || 'PO number not entered'} (new purchase order)"
  end

  def equipment_record_value(field, record)
    case field
    when 'product_id' then record ? equipment_catalog_label(record) : 'Catalog product no longer available'
    when 'purchase_order_id' then record ? "#{record.vendor.business_name} / #{record.number}" : 'Purchase order no longer available'
    when 'vendor_id' then record ? record.business_name : 'Vendor no longer available'
    end
  end

  def equipment_needs_value(rows, products:)
    return 'No new devices needed' if rows.blank?

    safe_join(rows.map do |row|
      "#{equipment_impact_value('product_id', row['product_id'], products: products)} — #{pluralize(row['remaining_quantity'], 'device')}"
    end, tag.br)
  end
end
