# frozen_string_literal: true

require 'test_helper'

class VoucherHelperTest < ActionView::TestCase
  setup do
    @vendor = create(:vendor)
    @purchase = create(:voucher_transaction, vendor: @vendor)
  end

  test 'fulfillment labels count packages and never claim the whole order shipped' do
    assert_equal 'Waiting for shipping details', fulfillment_status_label(@purchase)

    service = VoucherTransactions::FulfillmentService.new(transaction: @purchase, actor: @vendor)
    service.change_mode!(mode: :shipping, expected_version: 0)
    assert_equal 'Waiting for tracking', fulfillment_status_label(@purchase.reload)

    service.add_shipment!(attributes: { 'tracking_number' => 'AAA111' }, expected_version: 1)
    assert_equal '1 package sent', fulfillment_status_label(@purchase.reload)
    service.add_shipment!(attributes: { 'tracking_number' => 'BBB222' }, expected_version: 2)
    assert_equal '2 packages sent', fulfillment_status_label(@purchase.reload)
    I18n.with_locale(:es) { assert_equal '2 paquetes enviados', fulfillment_status_label(@purchase) }

    service.change_mode!(mode: :local_pickup, expected_version: 3)
    assert_equal 'Local pickup', fulfillment_status_label(@purchase.reload)
  end

  test 'purchases that cannot be fulfilled have no fulfillment label' do
    assert_nil fulfillment_status_label(create(:voucher_transaction, :pending, vendor: @vendor))
    assert_nil fulfillment_status_badge(create(:voucher_transaction, :pending, vendor: @vendor))
  end
end
