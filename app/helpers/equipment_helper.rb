# frozen_string_literal: true

module EquipmentHelper
  def equipment_wait_length(entered_at, now: Time.current)
    days = Equipment::WaitTime.days_since(entered_at, now:)
    return pluralize(days, 'day') if days < 7

    pluralize(days / 7, 'week')
  end

  def equipment_funding_label(record, abbreviated: false)
    equipment_funding_source_label(record.funding_source, abbreviated:)
  end

  def equipment_funding_source_label(source, fallback: source, abbreviated: false)
    return 'ICC' if abbreviated && source == 'icanconnect'

    { 'mat' => 'MAT', 'icanconnect' => 'iCanConnect' }.fetch(source, fallback)
  end

  def equipment_navigation_section
    case controller_path
    when 'admin/equipment' then :fulfillment
    when 'admin/bid_groups', 'admin/purchase_orders' then :purchasing
    when 'admin/stock' then :stock
    end
  end

  def equipment_navigation_label(section)
    { fulfillment: 'Needs bid number', purchasing: 'Enter PO details', stock: 'Stock' }.fetch(section)
  end

  def equipment_navigation_views(tab:)
    case equipment_navigation_section
    when :fulfillment
      [['Needs bid number', 'needs_ordering'], ['Enter shipping info', 'ordered'], ['View shipment history', 'shipped']].map do |label, view_tab|
        [label, admin_equipment_index_path(tab: view_tab), tab == view_tab]
      end
    when :purchasing
      [['Bids', admin_bid_groups_path, 'admin/bid_groups'], ['Purchase Orders', admin_purchase_orders_path, 'admin/purchase_orders']].map do |label, path, section|
        [label, path, controller_path == section]
      end
    when :stock
      []
    end
  end

  def equipment_device_summary(products)
    captions = products.map do |product|
      model = product.model_number.presence || product.name
      family = model.match(/\A(iPhone|iPad|Pixel|Galaxy)(?:\b|\d)/i)
      family ? family[1] : truncate(model, length: 26, separator: ' ')
    end.uniq
    return 'Device not yet selected' if captions.empty?

    captions.one? ? captions.first : "#{captions.first} + #{captions.size - 1} more"
  end

  def equipment_navigation_record_path(metric, tab:)
    case metric.oldest_record
    when BidGroup then new_admin_purchase_order_path(bid_group_id: metric.oldest_record.id)
    when PurchaseOrder then admin_purchase_order_path(metric.oldest_record)
    else admin_equipment_index_path(tab:, application_id: metric.oldest_application.id)
    end
  end

  def equipment_navigation_description(metric)
    groups = if metric.oldest_application
               labels = metric.oldest_application.program_disability_groups.filter_map { |group| Product::PROGRAM_GROUPS[group] }
               labels.to_sentence.presence || 'Disability group not recorded'
             end
    description = [groups, equipment_device_summary(metric.products)].compact.join(' ')
    return description if metric.additional_constituents.zero?

    "#{description} · + #{pluralize(metric.additional_constituents, 'other constituent')}"
  end

  def equipment_source_label(item)
    {
      'direct_vendor' => 'Supplier', 'program_stock_po' => 'Purchased for program stock', 'existing_stock' => 'Existing program stock'
    }.fetch(item.fulfillment_source)
  end

  TRACKING_DESTINATIONS = {
    'ups' => ['https://www.ups.com/track', 'tracknum', { 'loc' => 'en_US' }],
    'fedex' => ['https://www.fedex.com/apps/fedextrack/', 'tracknumbers', {}],
    'usps' => ['https://tools.usps.com/go/TrackConfirmAction', 'tLabels', {}],
    'dhl' => ['https://www.dhl.com/us-en/home/tracking.html', 'tracking-id', { 'submit' => '1' }]
  }.freeze
  EQUIPMENT_AUDIT_FIELDS = (Equipment::Correction::EDITABLE_ITEM_FIELDS + Equipment::Correction::PO_FIELDS +
    %w[equipment_needs bid_lines bid_group_ids remaining_quantity withdrawn_at purchase_order_id vendor_name unit_cost purpose funding_source
       shipping_cost tax_cost other_cost other_cost_category invoice_total vendor_invoice_number invoice_on delivered_on installed_on
       replaced_by_equipment_item_id amount service_date category hourly_rate billable_hours mileage mileage_rate
       funding_service_on equipment_item_id po_assigned_at]).freeze

  EQUIPMENT_AUDIT_ACTION_LABELS = {
    'equipment_bid_created' => 'Bid created', 'equipment_bid_amended' => 'Bid updated',
    'equipment_order_recorded' => 'PO recorded', 'equipment_po_sent' => 'PO sent', 'equipment_item_reordered' => 'Device reordered',
    'equipment_purchase_order_corrected' => 'PO details corrected', 'equipment_supplier_recorded' => 'Vendor updated',
    'equipment_purchase_cost_recorded' => 'Device price updated', 'equipment_needs_initialized' => 'Purchasing needs created',
    'equipment_needs_updated' => 'Purchasing needs updated', 'equipment_profile_updated' => 'Shipping address or device setup updated',
    'icc_financial_evidence_updated' => 'Financial details updated', 'icc_filed_cost_corrected' => 'Filed costs corrected',
    'icc_cost_marked_claimed' => 'Costs marked filed', 'icc_service_expense_recorded' => 'Service bill recorded'
  }.freeze

  def equipment_audit_action_label(event)
    return 'Shipment reported by vendor' if event.action == 'equipment_shipment_recorded' && event.metadata['purchase_order_shipping_request_id'].present?

    EQUIPMENT_AUDIT_ACTION_LABELS.fetch(event.action) { event.action.delete_prefix('equipment_').humanize }
  end

  def equipment_catalog_label(product)
    product&.catalog_label.to_s
  end

  def equipment_catalog_options(products)
    products.map { |product| [equipment_catalog_label(product), product.id] }
  end

  def equipment_stock_coverage(available_count, quantity)
    return '—' unless quantity.positive?
    return 'No' if available_count.zero?

    available_count >= quantity ? 'All' : 'Partial'
  end

  def equipment_request_setup(record)
    record.setup_ready? ? Product::PROGRAM_GROUPS.fetch(record.disability_setup_group, 'Setup needed') : 'Setup needed'
  end

  def equipment_need_setup_options(application, selected)
    options = Product::PROGRAM_GROUPS.slice(*application.program_disability_groups).map { |key, label| [label, key] }
    if selected.present? && application.program_disability_groups.exclude?(selected)
      options << ["#{Product::PROGRAM_GROUPS.fetch(selected, selected)} (no longer confirmed — choose setup)", selected]
    end
    options
  end

  def equipment_ordered_stock_setup(item)
    return 'Not recorded' unless item.acquisition_bid_group_line

    Product::PROGRAM_GROUPS[item.acquisition_bid_group_line.supplier_setup_group] || 'Unassigned'
  end

  def equipment_shipment_wait(item)
    entered_at = item.shipment_wait_started_at
    return 'Wait date unavailable' unless entered_at

    "#{pluralize(Equipment::WaitTime.days_since(entered_at), 'day')} waiting"
  end

  def equipment_dispatch_group_wait(group)
    unknown = group.items.count { |item| item.shipment_wait_started_at.nil? }
    text = if group.oldest_wait_at
             "Longest known wait: #{pluralize(Equipment::WaitTime.days_since(group.oldest_wait_at), 'day')}"
           else
             'Wait date unavailable'
           end
    unknown.positive? ? "#{text} · #{pluralize(unknown, 'device')} without a wait date" : text
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
                                  class: 'text-primary-700 underline'
  end

  def equipment_return_path(context)
    admin_equipment_index_path(Equipment::RequestParameters.return_context(context))
  end

  def equipment_queue_badge(item)
    labels = { 'needs_ordering' => 'Needs bid number', 'ready_to_send_po' => 'PO sent date needed',
               'available_stock' => 'Available stock', 'incoming_stock' => 'Incoming stock',
               'awaiting_shipment' => 'Shipping info needed',
               'shipped' => 'Shipment recorded', 'withdrawn' => 'Withdrawn' }
    state = item.queue_status
    status_badge(:equipment, state, label: labels.fetch(state))
  end

  def equipment_item_context_link(item, return_context:)
    if item.application_id
      link_to "Application ##{item.application_id}", admin_application_path(item.application_id, anchor: "equipment-item-#{item.id}", return_context: return_context),
              class: 'text-primary-700 underline'
    elsif item.purchase_order_id
      link_to "Stock PO #{item.purchase_order.number}", admin_purchase_order_path(item.purchase_order, return_context: return_context),
              class: 'text-primary-700 underline'
    else
      link_to 'Program stock', admin_stock_index_path(return_context: return_context), class: 'text-primary-700 underline'
    end
  end

  def equipment_disposition_action(item)
    return if item.shipped_at_in_database || item.withdrawn_at? || (item.stock? && item.application_id?)
    return if item.icc_financial_evidence_locked? || item.bid_group_lines.reserved.exists?

    if item.direct_vendor?
      item.purchase_order_id? ? ['detach', 'Remove from PO for reorder'] : ['withdraw', 'Cancel device request']
    else
      ['withdraw', item.stock_received_on_in_database ? 'Remove from stock' : 'Cancel incoming stock']
    end
  end

  def equipment_impact_value(field, value, products: [], purchase_orders: [], bid_groups: [])
    return equipment_needs_value(value, products: products) if field == 'equipment_needs'
    return equipment_bid_lines_value(value, products: products) if field == 'bid_lines'
    return equipment_bid_groups_value(value, bid_groups: bid_groups) if field == 'bid_group_ids'
    return 'Not recorded' if value.blank?

    money_fields = %w[unit_cost shipping_cost tax_cost other_cost invoice_total amount hourly_rate mileage_rate]
    return number_to_currency(value, precision: { 'mileage_rate' => 3 }.fetch(field, 2)) if money_fields.include?(field)
    return equipment_funding_source_label(value) if field == 'funding_source'
    return value.humanize if field == 'purpose'
    return EquipmentItem::CARRIERS.fetch(value, value) if field == 'carrier'
    if field.in?(%w[shipped_at sent_at stock_received_on withdrawn_at delivered_on installed_on invoice_on service_date funding_service_on po_assigned_at])
      return equipment_date_value(field, value)
    end

    records = { 'product_id' => products, 'purchase_order_id' => purchase_orders }
    return value unless records.key?(field)

    equipment_record_value(field, records[field].find { |candidate| candidate.id.to_s == value.to_s })
  end

  def equipment_field_label(field)
    labels = { 'bid_lines' => 'Reserved products', 'bid_group_ids' => 'Bids', 'equipment_needs' => 'Purchasing needs', 'unit_cost' => 'Price per device',
               'vendor_name' => 'Supplier name',
               'mileage' => 'Mileage (miles)', 'mileage_rate' => 'Cost per mile', 'po_assigned_at' => 'Date assigned to PO' }
    return labels[field] if labels.key?(field)

    model = if field.in?(Equipment::Correction::PO_FIELDS)
              PurchaseOrder
            elsif field == 'remaining_quantity'
              EquipmentNeed
            else
              EquipmentItem
            end
    model.human_attribute_name(field)
  end

  def equipment_audit_changes(event, records:)
    changes = equipment_history_change_pairs(event).filter_map do |field, values|
      next unless EQUIPMENT_AUDIT_FIELDS.include?(field)

      [field, field == 'number' && event.auditable_type == 'BidGroup' ? 'Bid number' : equipment_field_label(field), *values]
    end
    render('admin/equipment/audit_changes', changes:, records:, initial: event.action == 'equipment_bid_created') if changes.any?
  end

  def equipment_audit_details(event, records:)
    notes = [event.metadata['reason'], event.metadata['correction_reason']]
    reference = event.metadata['external_filing_reference']
    notes << "External correction reference: #{reference}" if event.action == 'icc_filed_cost_corrected' && reference.present?
    if event.action == 'icc_cost_marked_claimed'
      notes << "Filing period: #{event.metadata['period']} · Reference: #{event.metadata['external_filing_reference']} " \
               "· Amount: #{number_to_currency(event.metadata['amount'])}"
    elsif event.action.start_with?('icc_') && event.metadata.dig('before', 'financial_document_blob_id') != event.metadata.dig('after', 'financial_document_blob_id')
      notes << 'Supporting document updated'
    end
    acknowledgment = event.field_change_pairs.fetch('serial_duplicate_reason', []).last
    notes << "Serial warning acknowledgment: #{acknowledgment}" if acknowledgment.present?
    details = [equipment_audit_changes(event, records:), *notes.compact_blank.map { |note| tag.p(note) }].compact
    tag.div(safe_join(details), class: 'space-y-2') if details.any?
  end

  def equipment_correction_changes(record, previous_values, fields:)
    fields.filter_map do |field|
      before = previous_values[field]
      value = record.public_send(field)
      next if before == value && record.try(:"rejected_#{field}_input").blank?

      after = field.in?(%w[shipped_at sent_at]) ? typed_date_input_value(record, field) : value
      [field, equipment_field_label(field), before, after]
    end
  end

  private

  def equipment_history_change_pairs(event)
    return event.field_change_pairs if !event.action.start_with?('icc_') || event.field_changes.any?

    before = event.metadata.fetch('before', {})
    after = event.metadata.fetch('after', {})
    EQUIPMENT_AUDIT_FIELDS.each_with_object({}) do |field, changes|
      changes[field] = [before[field], after[field]] if before[field] != after[field]
    end
  end

  def equipment_date_value(field, value)
    value = parse_activity_time(value) || value if field == 'withdrawn_at'
    accessible_date_value(value) || 'Not recorded'
  end

  def equipment_record_value(field, record)
    case field
    when 'product_id' then record ? equipment_catalog_label(record) : 'Catalog product no longer available'
    when 'purchase_order_id' then record ? "#{record.number} · #{record.purpose.humanize}" : 'Purchase order no longer available'
    end
  end

  def equipment_needs_value(rows, products:)
    return 'No new devices needed' if rows.blank?

    safe_join(rows.map do |row|
      setup = Product::PROGRAM_GROUPS[row['disability_setup_group']]
      ["#{equipment_impact_value('product_id', row['product_id'], products: products)} — #{pluralize(row['remaining_quantity'], 'device')}", setup].compact.join(' · ')
    end, tag.br)
  end

  def equipment_bid_lines_value(rows, products:)
    return 'No products reserved' if rows.blank?

    safe_join(rows.map do |row|
      setup = Product::PROGRAM_GROUPS[row['supplier_setup_group']]
      status = row['released_at'].present? ? 'Released' : 'Reserved'
      price = if row.key?('unit_cost')
                row['unit_cost'].nil? ? 'Price not recorded' : "#{number_to_currency(row['unit_cost'])} per device"
              end
      model = equipment_impact_value('product_id', row['product_id'], products: products)
      ["#{model} — #{pluralize(row['quantity'], 'device')}", setup, status, price].compact.join(' · ')
    end, tag.br)
  end

  def equipment_bid_groups_value(ids, bid_groups:)
    return 'No bids' if ids.blank?

    ids.map do |id|
      group = bid_groups.find { |candidate| candidate.id.to_s == id.to_s }
      group ? "Bid #{group.number}" : 'Bid no longer available'
    end.join(', ')
  end
end
