# frozen_string_literal: true

require 'test_helper'

class VoucherHelperTest < ActionView::TestCase
  setup do
    @vendor = create(:vendor)
    @purchase = create(:voucher_transaction, vendor: @vendor)
  end

  test 'fulfillment labels count packages and only say tracking is available' do
    assert_equal 'Waiting for shipping details', fulfillment_status_label(@purchase)

    service = VoucherTransactions::FulfillmentService.new(transaction: @purchase, actor: @vendor)
    service.change_mode!(mode: :shipping, expected_version: 0)
    assert_equal 'Waiting for tracking', fulfillment_status_label(@purchase.reload)

    service.add_shipment!(attributes: { 'tracking_number' => 'AAA111' }, expected_version: 1)
    assert_equal 'Tracking available for 1 package', fulfillment_status_label(@purchase.reload)
    service.add_shipment!(attributes: { 'tracking_number' => 'BBB222' }, expected_version: 2)
    assert_equal 'Tracking available for 2 packages', fulfillment_status_label(@purchase.reload)
    I18n.with_locale(:es) { assert_equal 'Rastreo disponible para 2 paquetes', fulfillment_status_label(@purchase) }

    service.change_mode!(mode: :local_pickup, expected_version: 3)
    assert_equal 'Local pickup', fulfillment_status_label(@purchase.reload)
  end

  test 'purchases that cannot be fulfilled have no fulfillment label' do
    assert_nil fulfillment_status_label(create(:voucher_transaction, :pending, vendor: @vendor))
    assert_nil fulfillment_status_badge(create(:voucher_transaction, :pending, vendor: @vendor))
  end

  test 'transaction status badges name each stored status' do
    { transaction_completed: %w[Completed bg-green-100], transaction_pending: %w[Pending bg-yellow-100],
      transaction_failed: %w[Failed bg-red-100], transaction_cancelled: %w[Cancelled bg-yellow-100] }.each do |status, (label, color)|
      badge = voucher_transaction_status_badge(build(:voucher_transaction, status: status))

      assert_includes badge, ">#{label}</span>", status
      assert_includes badge, color, status
    end
  end

  test 'voucher usage exposes the exact percentage without inline styles' do
    voucher = Voucher.new(initial_value: 1000, remaining_value: 630, status: :active)
    progress = Nokogiri::HTML.fragment(voucher_usage_bar(voucher)).at_css('progress')

    assert_equal '37', progress['value']
    assert_equal '100', progress['max']
    assert_equal 'Voucher value used', progress['aria-label']
    assert_equal '37%', progress.text
    assert_nil progress['style']
  end

  test 'voucher usage remains determinate for redeemed and zero value vouchers' do
    [
      [Voucher.new(initial_value: 500, remaining_value: 0, status: :redeemed), '100'],
      [Voucher.new(initial_value: 0, remaining_value: 0, status: :active), '0']
    ].each do |voucher, percentage|
      progress = Nokogiri::HTML.fragment(voucher_usage_bar(voucher)).at_css('progress')

      assert_equal percentage, progress['value']
      assert_equal '100', progress['max']
    end
  end
end
