# frozen_string_literal: true

require 'test_helper'

class EquipmentHelperTest < ActionView::TestCase
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

  test 'return context allowlists equipment tabs and numeric filters and rejects external paths' do
    assert_equal({}, equipment_return_context(nil))
    assert_equal({ tab: 'ordered', product_id: '7', vendor_id: '8' }, equipment_return_context(return_context: { tab: 'ordered', product_id: '7', vendor_id: '8', next: 'https://evil.example/' }))
    assert_equal({}, equipment_return_context(return_to: 'https://evil.example/admin/equipment?tab=shipped'))
    assert_equal({}, equipment_return_context(return_to: '//evil.example/admin/equipment'))
    assert_equal({}, equipment_return_context(tab: 'elsewhere', product_id: '-1', vendor_id: 'bad'))
  end
end
