# frozen_string_literal: true

require 'test_helper'

class EquipmentHelperTest < ActionView::TestCase
  include ActivityHistoryHelper
  include DateInputHelper
  include Admin::ApplicationsHelper

  test 'equipment waits use days then whole weeks and funding labels retain their capitalization' do
    today = Date.new(2026, 11, 13)
    assert_equal '0 days', equipment_wait_length(today, now: today)
    assert_equal '1 day', equipment_wait_length(today - 1, now: today)
    assert_equal '6 days', equipment_wait_length(today - 6, now: today)
    assert_equal '1 week', equipment_wait_length(today - 7, now: today)
    assert_equal '3 weeks', equipment_wait_length(today - 21, now: today)
    now = Time.zone.local(2026, 11, 13, 1)
    assert_equal '0 days', equipment_wait_length(now - 2.hours, now:)
    assert_equal '0 days', equipment_wait_length(now + 1.hour, now:)
    assert_equal 'MAT', equipment_funding_label(BidGroup.new(funding_source: 'mat'))
    assert_equal 'iCanConnect', equipment_funding_label(BidGroup.new(funding_source: 'icanconnect'))
    assert_equal 'ICC', equipment_funding_label(BidGroup.new(funding_source: 'icanconnect'), abbreviated: true)
    assert_equal 'MAT', equipment_funding_source_label('mat')
    assert_equal 'iCanConnect', equipment_funding_source_label('icanconnect')
    assert_nil equipment_funding_source_label(nil)
    assert_equal 'retired_source', equipment_funding_source_label('retired_source')
    assert_equal 'Not recorded yet', equipment_funding_source_label(nil, fallback: 'Not recorded yet')
    assert_equal 'Not recorded yet', equipment_funding_source_label('retired_source', fallback: 'Not recorded yet')
    assert_equal 'retired_source', equipment_impact_value('funding_source', 'retired_source')
    assert_equal 'Not recorded', equipment_impact_value('funding_source', nil)
  end

  test 'stock coverage compares available units with the requested quantity' do
    assert_equal 'No', equipment_stock_coverage(0, 1)
    assert_equal 'Partial', equipment_stock_coverage(1, 2)
    assert_equal 'All', equipment_stock_coverage(2, 2)
    assert_equal 'All', equipment_stock_coverage(3, 2)
  end

  test 'stock coverage is not applicable when there is no quantity to fulfill' do
    assert_equal '—', equipment_stock_coverage(0, 0)
    assert_equal '—', equipment_stock_coverage(2, 0)
    assert_equal '—', equipment_stock_coverage(2, -1)
  end

  test 'tracking destinations are fixed official HTTPS hosts and encode only the tracking number' do
    {
      'ups' => ['www.ups.com', 'tracknum'], 'fedex' => ['www.fedex.com', 'tracknumbers'],
      'usps' => ['tools.usps.com', 'tLabels'], 'dhl' => ['www.dhl.com', 'tracking-id']
    }.each do |carrier, (host, parameter)|
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
    assert_empty equipment_correction_changes(item, previous, fields: fields)

    item.carrier = 'fedex'
    item.shipped_at = '13/45/2026'
    assert_equal %w[carrier shipped_at], equipment_correction_changes(item, previous, fields: fields).map(&:first)
    assert_equal 'FedEx', equipment_impact_value('carrier', item.carrier)
    assert_equal '13/45/2026', equipment_impact_value('shipped_at', typed_date_input_value(item, :shipped_at))
    assert_equal '09/09/2026', equipment_impact_value('sent_at', '2026-09-09')
  end

  test 'history resolves one event collection in bounded queries and escapes recorded text' do
    product = create(:product, name: 'History Phone', model_number: 'History Phone <script>')
    needs_product = create(:product, name: 'Nested purchasing model', model_number: 'Nested purchasing model')
    order = create(:purchase_order)
    events = 10.times.map do
      Event.new(action: 'equipment_item_corrected', metadata: { 'changes' => {
                  'product_id' => [nil, product.id], 'purchase_order_id' => [nil, order.id],
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

    assert_operator queries.size, :<=, 2
    assert(rendered.all? { |html| html.include?(order.number) && html.include?('Direct to constituents') })
    assert_includes rendered.first, 'History Phone &lt;script&gt;'
    assert_includes rendered.first, 'Nested purchasing model'
    assert_not_includes rendered.first, '<script>'
    assert_not_includes rendered.first, 'INTERNAL-'
    assert_not_includes rendered.first, 'Id:'
    assert_not_includes rendered.first, 'Lock version:'
    assert_not_includes rendered.first, 'Created at:'
  end

  test 'encrypted serial acknowledgments are escaped in rendered history' do
    acknowledgment = 'Manufacturer review <script>alert(1)</script>'
    event = Event.new(action: 'equipment_item_corrected', user: build(:admin), created_at: Time.current,
                      metadata: { 'changes' => { 'serial_duplicate_reason' => {} } },
                      change_values: { serial_duplicate_reason: [nil, acknowledgment] }.to_json)

    render partial: 'admin/equipment_items/history', locals: { events: [event], audit_records: {} }

    assert_select 'p', text: "Serial warning acknowledgment: #{acknowledgment}"
    assert_select 'script', count: 0
  end

  test 'bid and PO history names the actor and shows readable recorded changes without raw identifiers' do
    product = create(:product, name: 'History quote phone')
    bid = BidGroup.new(id: 123, number: 'HISTORY-BID')
    actor = build(:admin, first_name: 'Morgan', last_name: 'Editor')
    recorded_at = Time.zone.local(2026, 11, 14, 10, 30)
    event = Event.new(action: 'equipment_bid_amended', auditable: bid, user: actor, created_at: recorded_at,
                      metadata: { changes: { bid_lines: [[], [{ product_id: product.id, quantity: 2, supplier_setup_group: 'deaf', released_at: nil, unit_cost: '49.95' }]],
                                             number: [nil, bid.number], bid_group_ids: [[], [bid.id]], vendor_name: [nil, '<script>Vendor</script>'], unit_cost: [nil, '49.95'] },
                                  reason: 'Corrected the quoted quantity' }.deep_stringify_keys)
    records = { products: [product], purchase_orders: [], bid_groups: [bid] }

    render partial: 'admin/equipment_items/history', locals: { events: [event], audit_records: records, title: 'Bid history', expanded: true, history_id: 'bid-history' }

    assert_select '#bid-history[open]'
    assert_select '#bid-history', text: /Bid updated — Morgan Editor/
    assert_select 'time[datetime=?]', recorded_at.iso8601
    assert_select '#bid-history', text: /#{Regexp.escape(product.catalog_label)} — 2 devices · Deaf · Reserved · \$49.95 per device/
    assert_select '#bid-history dt', text: 'Bids'
    assert_select '#bid-history dd', text: 'Bid HISTORY-BID'
    assert_select '#bid-history dt', text: 'Bid number'
    assert_select '#bid-history dd', text: 'HISTORY-BID'
    assert_select '#bid-history dt', text: 'Price per device'
    assert_select '#bid-history dd', text: '$49.95'
    assert_not_includes rendered, 'Not recorded →'
    assert_not_includes rendered, 'No products reserved →'
    assert_not_includes rendered, 'No bids →'
    assert_select '#bid-history', text: /Corrected the quoted quantity/
    assert_select 'script', count: 0
    assert_not_includes rendered, 'Product id'
    assert_not_includes rendered, 'Line ids'
    assert_not_includes rendered, 'PO number:'
    row = { 'product_id' => product.id, 'quantity' => 1 }
    assert_not_includes equipment_impact_value('bid_lines', [row], products: [product]), 'Price not recorded'
    assert_includes equipment_impact_value('bid_lines', [row.merge('unit_cost' => nil)], products: [product]), 'Price not recorded'
  end

  test 'empty history has an explicit message and no duplicate blank identifier' do
    render partial: 'admin/equipment_items/history', locals: { events: [], audit_records: {} }

    assert_select 'details:not([open])'
    assert_select 'details[id]', count: 0
    assert_select 'li', text: 'No activity has been recorded yet.'
  end

  test 'financial history formats existing before and after evidence without exposing document identifiers' do
    event = Event.new(action: 'icc_filed_cost_corrected', metadata: {
      before: { unit_cost: '100', delivered_on: nil, financial_document_blob_id: 123 },
      after: { unit_cost: '125.50', delivered_on: '2026-11-14', financial_document_blob_id: 456 },
      correction_reason: 'Corrected vendor invoice <script>', changed_fields: %w[unit_cost delivered_on]
    }.deep_stringify_keys)

    details = equipment_audit_details(event, records: {})

    assert_equal 'Filed costs corrected', equipment_audit_action_label(event)
    comparison = Nokogiri::HTML5.fragment(details)
    assert_equal %w[Field Before After], comparison.css('thead th').map(&:text)
    changes = comparison.css('tbody tr').map { |row| row.css('th, td').map(&:text) }
    assert_includes changes, ['Price per device', '$100.00', '$125.50']
    assert_includes changes, ['Date received', 'No value', '11/14/2026']
    assert_includes details, '11/14/2026'
    assert_includes details, 'Supporting document updated'
    assert_includes details, 'Corrected vendor invoice &lt;script&gt;'
    assert_not_includes details, '123'
    assert_not_includes details, '456'

    event.metadata = { before: { unit_cost: '0', vendor_name: 'Previous vendor' },
                       after: { unit_cost: '25', vendor_name: nil } }.deep_stringify_keys
    details = equipment_audit_changes(event, records: {})
    changes = Nokogiri::HTML5.fragment(details).css('tbody tr').map { |row| row.css('th, td').map(&:text) }
    assert_includes changes, ['Price per device', '$0.00', '$25.00']
    assert_includes changes, ['Supplier name', 'Previous vendor', 'Cleared']
  end

  test 'missing historical records have truthful names rather than numeric identifiers' do
    { 'product_id' => 'Catalog product no longer available', 'purchase_order_id' => 'Purchase order no longer available' }.each do |field, label|
      assert_equal label, equipment_impact_value(field, 123)
      assert_equal 'Not recorded', equipment_impact_value(field, nil)
      assert_equal 'Not recorded', equipment_impact_value(field, '')
    end
  end
end
