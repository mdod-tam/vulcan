# frozen_string_literal: true

require 'test_helper'

module VendorPortal
  class ShipmentsControllerTest < ActionDispatch::IntegrationTest
    include AuthenticationTestHelper

    setup do
      @vendor = create(:vendor_user)
      sign_in_with_headers(@vendor)
      @purchase = create(:voucher_transaction, vendor: @vendor)
    end

    test 'recording a package saves it and queues its notice' do
      assert_enqueued_with(job: VoucherTransactions::TrackingNoticeJob) do
        post vendor_portal_transaction_shipments_url(@purchase),
             params: { fulfillment_version: 0, shipment: { tracking_number: '1Z999', dispatched_on: '9/9/2026', contents: 'Phone' } }
      end

      assert_redirected_to vendor_portal_transaction_path(@purchase)
      shipment = @purchase.shipments.sole
      assert_equal ['1Z999', Date.new(2026, 9, 9), 'Phone'], [shipment.tracking_number, shipment.dispatched_on, shipment.contents]
    end

    test 'an invalid package re-renders with the typed input and an error summary' do
      post vendor_portal_transaction_shipments_url(@purchase),
           params: { fulfillment_version: 0, shipment: { tracking_number: '', dispatched_on: '13/45/2026' } }

      assert_response :unprocessable_content
      assert_select '#new_shipment_errors[role=alert]'
      assert_select '#new_shipment_errors a[href="#new_shipment_shipment_tracking_number"]', text: /Tracking number can't be blank/
      assert_select '#new_shipment_errors', text: %r{Ship date is not a valid date. Enter it as MM/DD/YYYY}
      assert_select 'input#new_shipment_shipment_dispatched_on[value="13/45/2026"][aria-invalid=true]'
      assert_select 'input[name=fulfillment_version][value="0"]'
      assert_empty @purchase.shipments
    end

    test 'a duplicate tracking number is refused and a stale add-package form is refused' do
      post vendor_portal_transaction_shipments_url(@purchase), params: { fulfillment_version: 0, shipment: { tracking_number: 'AAA111' } }
      post vendor_portal_transaction_shipments_url(@purchase), params: { fulfillment_version: 1, shipment: { tracking_number: 'aaa-111' } }
      assert_response :unprocessable_content
      assert_select '#new_shipment_errors', text: /already recorded for this purchase/

      post vendor_portal_transaction_shipments_url(@purchase), params: { fulfillment_version: 0, shipment: { tracking_number: 'BBB222' } }
      assert_match(/Someone else changed this purchase/, flash[:alert])
      assert_equal %w[AAA111], @purchase.shipments.pluck(:tracking_number)
    end

    test 'a correction is saved; a stale or invalid one is not' do
      shipment = record('AAA111')

      patch vendor_portal_transaction_shipment_url(@purchase, shipment),
            params: { shipment: { tracking_number: 'AAA112', lock_version: shipment.lock_version } }
      assert_redirected_to vendor_portal_transaction_path(@purchase)
      assert_equal 'AAA112', shipment.reload.tracking_number

      patch vendor_portal_transaction_shipment_url(@purchase, shipment),
            params: { shipment: { tracking_number: 'AAA113', lock_version: shipment.lock_version - 1 } }
      assert_match(/Someone else changed this purchase/, flash[:alert])

      patch vendor_portal_transaction_shipment_url(@purchase, shipment),
            params: { shipment: { tracking_number: '', lock_version: shipment.lock_version } }
      assert_response :unprocessable_content
      assert_select "details[open] #shipment_#{shipment.id}_errors"
      assert_equal 'AAA112', shipment.reload.tracking_number
    end

    test 'only the editable fields are accepted' do
      other_purchase = create(:voucher_transaction, vendor: @vendor)

      post vendor_portal_transaction_shipments_url(@purchase),
           params: { fulfillment_version: 0, shipment: { tracking_number: 'AAA111', voucher_transaction_id: other_purchase.id,
                                                         created_by_id: create(:admin).id } }

      shipment = @purchase.shipments.sole
      assert_equal @vendor, shipment.created_by
      assert_empty other_purchase.shipments
    end

    test 'another vendor\'s purchase, or a package from another purchase, is not found' do
      foreign_purchase = create(:voucher_transaction, vendor: create(:vendor_user))
      post vendor_portal_transaction_shipments_url(foreign_purchase), params: { fulfillment_version: 0, shipment: { tracking_number: 'X1' } }
      assert_response :not_found
      assert_empty foreign_purchase.shipments

      my_other_purchase = create(:voucher_transaction, vendor: @vendor)
      shipment = VoucherTransactions::FulfillmentService.new(transaction: my_other_purchase, actor: @vendor)
                                                        .add_shipment!(attributes: { 'tracking_number' => 'ZZZ999' }, expected_version: 0)
      patch vendor_portal_transaction_shipment_url(@purchase, shipment), params: { shipment: { tracking_number: 'X', lock_version: 0 } }
      assert_response :not_found
      assert_equal 'ZZZ999', shipment.reload.tracking_number
    end

    test 'a pending purchase cannot be given packages' do
      pending = create(:voucher_transaction, :pending, vendor: @vendor)

      post vendor_portal_transaction_shipments_url(pending), params: { fulfillment_version: 0, shipment: { tracking_number: 'AAA111' } }

      assert_equal 'Only a completed purchase can have shipping details.', flash[:alert]
      assert_empty pending.shipments
    end

    private

    def record(tracking_number)
      VoucherTransactions::FulfillmentService.new(transaction: @purchase, actor: @vendor)
                                             .add_shipment!(attributes: { 'tracking_number' => tracking_number },
                                                            expected_version: @purchase.reload.fulfillment_version)
    end
  end
end
