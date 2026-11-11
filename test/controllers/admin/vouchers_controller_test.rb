# frozen_string_literal: true

require 'test_helper'

module Admin
  # Cancellation is the admin's only way to change a voucher; redemption and expiry own every other status.
  class VouchersControllerTest < ActionDispatch::IntegrationTest
    setup do
      sign_in_for_integration_test(create(:admin), bypass_mfa_enrollment: true)
    end

    test 'no generic update route exists, so a request cannot change a voucher\'s status' do
      voucher = create(:voucher, :cancelled)
      path = admin_voucher_path(voucher)

      %i[patch put].each do |verb|
        assert_raises(ActionController::RoutingError, "#{verb} should not be routable") do
          Rails.application.routes.recognize_path(path, method: verb)
        end

        public_send(verb, path, params: { voucher: { status: 'active', notes: 'Reopened' } })

        assert_response :not_found
        assert_predicate voucher.reload, :voucher_cancelled?, "#{verb} must leave the voucher cancelled"
        assert_nil voucher.notes
      end
    end

    test 'cancelling an active voucher cancels it, records one admin audit event, and returns to the voucher' do
      voucher = create(:voucher, :active)

      assert_difference -> { voucher.events.where(action: 'voucher_cancelled').count }, 1 do
        patch cancel_admin_voucher_path(voucher)
      end

      assert_redirected_to admin_voucher_path(voucher)
      assert_predicate voucher.reload, :voucher_cancelled?
      assert_match(/\ACancelled at /, voucher.notes)
    end

    test 'cancelling a redeemed voucher is refused and leaves it redeemed with no cancellation event' do
      voucher = create(:voucher, :redeemed)

      assert_no_difference -> { voucher.events.where(action: 'voucher_cancelled').count } do
        patch cancel_admin_voucher_path(voucher)
      end

      assert_redirected_to admin_voucher_path(voucher)
      assert_equal 'Cannot cancel this voucher', flash[:alert]
      assert_predicate voucher.reload, :voucher_redeemed?
    end
  end
end
