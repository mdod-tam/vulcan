# frozen_string_literal: true

require 'test_helper'

module Admin
  class BillingHoldsControllerTest < ActionDispatch::IntegrationTest
    setup do
      ensure_system_audit_actor!
      @admin = create(:admin)
      @purchase = create(:voucher_transaction, vendor: create(:vendor, :approved))
      sign_in_for_integration_test(@admin)
    end

    test 'staff hold a purchase with a reason, see it on the voucher, and release it' do
      post admin_voucher_transaction_billing_hold_path(@purchase), params: { reason: 'Possible duplicate sale' }

      assert_redirected_to admin_voucher_path(@purchase.voucher)
      assert @purchase.reload.on_billing_hold?
      assert_equal @admin, @purchase.billing_hold_by
      follow_redirect!
      assert_match 'Possible duplicate sale', response.body
      assert_select "form[aria-label='Release hold on purchase #{@purchase.reference_number}']"

      delete admin_voucher_transaction_billing_hold_path(@purchase)

      assert_not @purchase.reload.on_billing_hold?
      assert_equal %w[voucher_transaction_billing_hold_placed voucher_transaction_billing_hold_released],
                   Event.where(auditable: @purchase.voucher).where('action LIKE ?', 'voucher_transaction_billing_hold%').order(:id).pluck(:action)
    end

    test 'a hold needs a reason' do
      post admin_voucher_transaction_billing_hold_path(@purchase), params: { reason: '' }

      assert_redirected_to admin_voucher_path(@purchase.voucher)
      assert flash[:alert].present?
      assert_not @purchase.reload.on_billing_hold?
    end

    test 'only admins can hold purchases' do
      sign_in_for_integration_test(create(:trainer))

      post admin_voucher_transaction_billing_hold_path(@purchase), params: { reason: 'Nope' }

      assert_not @purchase.reload.on_billing_hold?
    end
  end
end
