# frozen_string_literal: true

require 'test_helper'

class EquipmentHelperTest < ActionView::TestCase
  include ActivityHistoryHelper
  include DateInputHelper

  test 'tracking destinations are fixed official HTTPS hosts and encode only the tracking number' do
    { 'ups' => ['www.ups.com', 'tracknum'], 'fedex' => ['www.fedex.com', 'tracknumbers'], 'usps' => ['tools.usps.com', 'tLabels'] }.each do |carrier, (host, parameter)|
      item = EquipmentItem.new(carrier: carrier, tracking_number: 'A B&?/#')
      uri = URI(equipment_tracking_url(item))
      assert_equal 'https', uri.scheme
      assert_equal host, uri.host
      assert_equal item.tracking_number, URI.decode_www_form(uri.query).to_h.fetch(parameter)
      assert_nil uri.fragment
      link = Nokogiri::HTML.fragment(equipment_tracking_link(item)).at_css('a')
      assert_equal '_blank', link['target']
      assert_equal 'noopener noreferrer', link['rel']
      assert_equal 'no-referrer', link['referrerpolicy']
      assert_includes link['aria-label'], EquipmentItem::CARRIERS.fetch(carrier)
    end
  end

  test 'unsupported or missing carrier and tracking produce no link' do
    assert_nil equipment_tracking_url(EquipmentItem.new(carrier: 'other', tracking_number: 'Package'))
    assert_nil equipment_tracking_url(EquipmentItem.new(tracking_number: 'Package'))
    assert_nil equipment_tracking_url(EquipmentItem.new(carrier: 'ups'))
    assert_nil equipment_tracking_url(EquipmentItem.new(carrier: 'https://evil.example/', tracking_number: 'Package'))
  end

  test 'impact previews include only changed values and preserve invalid date drafts' do
    item = EquipmentItem.new(carrier: 'ups', purchase_order_id: 7)
    fields = %w[carrier purchase_order_id shipped_at]
    previous = item.attributes.slice(*fields)
    assert_empty equipment_impact_fields(item, previous, fields: fields)

    item.carrier = 'fedex'
    item.shipped_at = '13/45/2026'
    assert_equal %w[carrier shipped_at], equipment_impact_fields(item, previous, fields: fields)
    assert_equal fields, equipment_impact_fields(item, previous, fields: fields, new_purchase_order: PurchaseOrder.new)
    assert_equal 'FedEx', equipment_impact_value('carrier', item.carrier)
    assert_equal '13/45/2026', equipment_impact_value('shipped_at', typed_date_input_value(item, :shipped_at))
    assert_equal '09/09/2026', equipment_impact_value('sent_at', '2026-09-09')
  end

  test 'history resolves one event collection in bounded queries and escapes recorded text' do
    product = create(:product, name: 'History Phone <script>')
    needs_product = create(:product, name: 'Nested purchasing model')
    order = create(:purchase_order)
    events = 10.times.map do
      Event.new(action: 'equipment_item_corrected', metadata: { 'changes' => {
                  'product_id' => [nil, product.id], 'purchase_order_id' => [nil, order.id], 'vendor_id' => [nil, order.vendor_id],
                  'equipment_needs' => { 'old' => [], 'new' => [{ 'product_id' => needs_product.id, 'remaining_quantity' => 2 }] },
                  'id' => [nil, 123], 'lock_version' => [0, 1], 'created_at' => [nil, Time.current.iso8601],
                  'normalized_serial_number' => [nil, 'INTERNAL-IDENTITY'], 'captured_model' => { 'new' => 'INTERNAL-SNAPSHOT' }
                } })
    end
    queries = []
    callback = lambda do |*args|
      sql = args.last[:sql]
      queries << sql if sql.match?(/\ASELECT .*"(?:products|purchase_orders|users)"/m)
    end
    rendered = []
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      records = Equipment::AuditRecords.for(events)
      lookup_queries = queries.size
      events.each { |event| rendered << equipment_audit_changes(event, records: records) }
      assert_equal lookup_queries, queries.size, 'Formatting prepared audit records must not load more records'
    end

    assert_operator queries.size, :<=, 4
    assert(rendered.all? { |html| html.include?(order.number) && html.include?(order.vendor.business_name) })
    assert_includes rendered.first, 'History Phone &lt;script&gt;'
    assert_includes rendered.first, 'Nested purchasing model'
    assert_not_includes rendered.first, '<script>'
    assert_not_includes rendered.first, 'INTERNAL-'
    assert_not_includes rendered.first, 'Id:'
    assert_not_includes rendered.first, 'Lock version:'
    assert_not_includes rendered.first, 'Created at:'
  end

  test 'captured plaintext serial acknowledgments remain readable in rendered history' do
    event = Event.new(action: 'equipment_item_corrected', user: build(:admin), created_at: Time.current,
                      metadata: { 'serial_duplicate_reason' => 'Earlier manufacturer review.' })

    render partial: 'admin/equipment_items/history', locals: { events: [event], audit_records: {} }

    assert_select 'p', text: 'Serial warning acknowledgment: Earlier manufacturer review.'
  end

  test 'missing historical records have truthful names rather than numeric identifiers' do
    { 'product_id' => 'Catalog product no longer available', 'purchase_order_id' => 'Purchase order no longer available',
      'vendor_id' => 'Vendor no longer available' }.each do |field, label|
      assert_equal label, equipment_impact_value(field, 123)
      assert_equal 'Not recorded', equipment_impact_value(field, nil)
      assert_equal 'Not recorded', equipment_impact_value(field, '')
    end
  end
end
