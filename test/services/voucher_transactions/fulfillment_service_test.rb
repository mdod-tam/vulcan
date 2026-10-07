# frozen_string_literal: true

require 'test_helper'

module VoucherTransactions
  class FulfillmentServiceTest < ActiveSupport::TestCase
    setup do
      @vendor = create(:vendor, :approved)
      @voucher = create(:voucher, :active, vendor: @vendor, initial_value: 500)
      @purchase = create(:voucher_transaction, voucher: @voucher, vendor: @vendor, amount: 100)
    end

    test 'recording a package makes the purchase shipping, bumps the version, audits, and sends nothing' do
      shipment = nil
      assert_no_enqueued_jobs do
        assert_no_difference('Notification.count') do
          shipment = service.add_shipment!(attributes: { 'tracking_number' => ' 1z-999 aa1 ' }, expected_version: 0)
        end
      end

      @purchase.reload
      assert @purchase.fulfillment_shipping?
      assert_equal 1, @purchase.fulfillment_version
      assert_equal '1z-999 aa1', shipment.tracking_number
      assert_equal '1Z999AA1', shipment.normalized_tracking_number
      assert_equal @vendor, shipment.created_by

      event = Event.find_by!(action: 'shipment_added', auditable: @purchase)
      assert_equal shipment.id, event.metadata['shipment_id']
      assert_equal({ 'old' => 'unspecified', 'new' => 'shipping' }, event.metadata.dig('changes', 'fulfillment_mode'))
    end

    test 'a form showing an older purchase version is refused for packages and mode changes' do
      service.add_shipment!(attributes: { 'tracking_number' => 'AAA111' }, expected_version: 0)

      assert_raises(FulfillmentService::StaleError) do
        service.add_shipment!(attributes: { 'tracking_number' => 'BBB222' }, expected_version: 0)
      end
      assert_raises(FulfillmentService::StaleError) { service.change_mode!(mode: :local_pickup, expected_version: 0) }
      assert_equal 1, @purchase.shipments.count
      assert @purchase.reload.fulfillment_shipping?
    end

    test 'choosing the mode the purchase already has changes nothing and records nothing' do
      service.change_mode!(mode: :local_pickup, expected_version: 0)

      service.change_mode!(mode: :local_pickup, expected_version: 1)

      assert_equal 1, @purchase.reload.fulfillment_version, 'another open form must not go stale'
      assert_equal 1, Event.where(action: 'fulfillment_mode_changed', auditable: @purchase).count
    end

    test 'fulfillment events carry the voucher so its admin audit log shows them' do
      service.add_shipment!(attributes: { 'tracking_number' => 'AAA111' }, expected_version: 0)

      assert_includes Vouchers::VoucherAuditLogBuilder.new(@voucher).build_audit_logs.map(&:action), 'shipment_added'
    end

    test 'switching to pickup after packages were recorded keeps them as history' do
      service.add_shipment!(attributes: { 'tracking_number' => 'AAA111' }, expected_version: 0)
      service.change_mode!(mode: :local_pickup, expected_version: 1)

      @purchase.reload
      assert @purchase.fulfillment_local_pickup?
      assert_equal %w[AAA111], @purchase.shipments.map(&:tracking_number)
    end

    test 'the same tracking number cannot be recorded twice on one purchase, but may be on another' do
      service.add_shipment!(attributes: { 'tracking_number' => '1z 999' }, expected_version: 0)

      error = assert_raises(ActiveRecord::RecordInvalid) do
        service.add_shipment!(attributes: { 'tracking_number' => '1Z-999' }, expected_version: 1)
      end
      assert_includes error.record.errors.full_messages, 'Tracking number is already recorded for this purchase'
      assert_equal 1, @purchase.reload.fulfillment_version, 'a refused package leaves the version unchanged'

      other = create(:voucher_transaction, voucher: create(:voucher, :active, vendor: @vendor), vendor: @vendor)
      FulfillmentService.new(transaction: other, actor: @vendor)
                        .add_shipment!(attributes: { 'tracking_number' => '1Z999' }, expected_version: 0)
      assert_equal 1, other.shipments.count
    end

    test 'a ship date in the future is refused' do
      error = assert_raises(ActiveRecord::RecordInvalid) do
        service.add_shipment!(attributes: { 'tracking_number' => 'AAA111', 'dispatched_on' => Date.tomorrow }, expected_version: 0)
      end
      assert_includes error.record.errors.full_messages, "Ship date can't be in the future"
    end

    test 'a correction from a stale package form is refused, and a current one is audited' do
      shipment = service.add_shipment!(attributes: { 'tracking_number' => 'AAA111' }, expected_version: 0)
      seen = shipment.lock_version

      service.correct_shipment!(shipment_id: shipment.id, attributes: { 'tracking_number' => 'AAA112' }, expected_lock_version: seen)
      assert_raises(FulfillmentService::StaleError) do
        service.correct_shipment!(shipment_id: shipment.id, attributes: { 'tracking_number' => 'AAA113' }, expected_lock_version: seen)
      end

      assert_equal 'AAA112', shipment.reload.tracking_number
      event = Event.find_by!(action: 'shipment_corrected', auditable: @purchase)
      assert_equal({ 'old' => 'AAA111', 'new' => 'AAA112' }, event.metadata.dig('changes', 'tracking_number'))
    end

    test 'only fields a vendor may edit are written' do
      shipment = service.add_shipment!(
        attributes: { 'tracking_number' => 'AAA111', 'voucher_transaction_id' => create(:voucher_transaction).id,
                      'created_by_id' => create(:admin).id }, expected_version: 0
      )

      assert_equal @purchase.id, shipment.voucher_transaction_id
      assert_equal @vendor, shipment.created_by
    end

    test 'a package belonging to another purchase cannot be corrected through this one' do
      other = create(:voucher_transaction, voucher: create(:voucher, :active, vendor: @vendor), vendor: @vendor)
      foreign = FulfillmentService.new(transaction: other, actor: @vendor)
                                  .add_shipment!(attributes: { 'tracking_number' => 'ZZZ999' }, expected_version: 0)

      assert_raises(ActiveRecord::RecordNotFound) do
        service.correct_shipment!(shipment_id: foreign.id, attributes: { 'tracking_number' => 'X' }, expected_lock_version: 0)
      end
    end

    test 'pending purchases and refunds cannot be fulfilled' do
      pending = create(:voucher_transaction, :pending, voucher: create(:voucher, :active, vendor: @vendor), vendor: @vendor)

      assert_raises(FulfillmentService::NotFulfillableError) do
        FulfillmentService.new(transaction: pending, actor: @vendor).change_mode!(mode: :shipping, expected_version: 0)
      end
    end

    private

    def service
      FulfillmentService.new(transaction: @purchase, actor: @vendor)
    end
  end
end
