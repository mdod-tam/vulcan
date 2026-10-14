# frozen_string_literal: true

module EquipmentHelper
  TRACKING_DESTINATIONS = {
    'ups' => ['https://www.ups.com/track', 'tracknum', { 'loc' => 'en_US' }],
    'fedex' => ['https://www.fedex.com/apps/fedextrack/', 'tracknumbers', {}],
    'usps' => ['https://tools.usps.com/go/TrackConfirmAction', 'tLabels', {}]
  }.freeze
  EQUIPMENT_TABS = %w[needs_ordering ordered shipped].freeze

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

  def equipment_return_context(source)
    source ||= {}
    source = source.with_indifferent_access if source.is_a?(Hash)
    context = source[:return_context] || source
    if source[:return_to].present?
      uri = URI.parse(source[:return_to].to_s)
      return {} unless uri.path == '/admin/equipment' && uri.host.nil? && uri.scheme.nil?

      context = Rack::Utils.parse_nested_query(uri.query.to_s).with_indifferent_access
    end
    result = {}
    result[:tab] = context[:tab] if EQUIPMENT_TABS.include?(context[:tab])
    %i[product_id vendor_id].each do |key|
      result[key] = context[key].to_s if context[key].to_s.match?(/\A[1-9]\d*\z/)
    end
    result
  rescue URI::InvalidURIError, TypeError
    {}
  end

  def equipment_return_path(context)
    admin_equipment_index_path(equipment_return_context(context))
  end

  def equipment_record_versions(source)
    return {} unless source.respond_to?(:each_pair)

    source.each_pair.filter_map { |id, version| [id.to_s, version.to_s] if id.to_s.match?(/\A\d+\z/) && version.is_a?(String) }.to_h
  end

  def equipment_queue_badge(item)
    labels = { 'needs_ordering' => 'Previously ordered device awaiting reorder', 'ordered' => 'Ordered',
               'shipped' => 'Shipped', 'withdrawn' => 'Withdrawn' }
    tag.span(labels.fetch(item.queue_status), class: 'rounded bg-gray-100 px-2 py-1 text-sm font-medium text-gray-800')
  end

  def equipment_impact_value(field, value, products: [], purchase_orders: [], vendors: [], new_purchase_order: nil)
    if field == 'purchase_order_id' && new_purchase_order
      vendor = vendors.find { |candidate| candidate.id == new_purchase_order.vendor_id }
      return "#{vendor&.business_name || 'Vendor not selected'} / #{new_purchase_order.number.presence || 'PO number not entered'} (new purchase order)"
    end
    records = { 'product_id' => products, 'purchase_order_id' => purchase_orders, 'vendor_id' => vendors }
    record = records.fetch(field, []).find { |candidate| candidate.id.to_s == value.to_s }
    return value.presence || 'Not recorded' unless record

    case field
    when 'product_id' then equipment_catalog_label(record)
    when 'purchase_order_id' then "#{record.vendor.business_name} / #{record.number}"
    when 'vendor_id' then record.business_name
    end
  end

  def equipment_audit_changes(event)
    event.field_changes.filter_map do |field, change|
      next if field.start_with?('normalized_') || field == 'manufacturer_model_identity'

      values = if change.is_a?(Array)
                 change
               elsif change.is_a?(Hash)
                 [change['old'], change['new']]
               else
                 [nil, change]
               end
      "#{field.humanize}: #{values.first.presence || 'Not recorded'} → #{values.last.presence || 'Not recorded'}"
    end.join('; ')
  end

  def equipment_items_for(application)
    application.equipment_items.includes(:product, events: :user, purchase_order: :vendor).order(:id)
  end

  def equipment_history_for(purchase_order)
    Event.where(auditable: purchase_order)
         .or(Event.where("metadata->'purchase_order_ids' @> ?::jsonb", [purchase_order.id].to_json))
         .includes(:user).order(created_at: :desc, id: :desc)
  end
end
