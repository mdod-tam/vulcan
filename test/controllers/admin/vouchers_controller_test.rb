# frozen_string_literal: true

require 'test_helper'

module Admin
  # Cancellation is the admin's only way to change a voucher; redemption and expiry own every other status.
  class VouchersControllerTest < ActionDispatch::IntegrationTest
    setup do
      sign_in_for_integration_test(create(:admin), bypass_mfa_enrollment: true)
    end

    test 'status cards distinguish active expiring redeemed and unassigned vouchers' do
      validity = Policy.find_or_create_by!(key: 'voucher_validity_period_months') { |policy| policy.value = 6 }
      vendor = create(:vendor, :approved)
      active = create(:voucher, :active, vendor: vendor, application: create(:application, skip_proofs: true))
      expiring = create(
        :voucher, :active,
        vendor: vendor,
        issued_at: 3.days.from_now - validity.value.months,
        application: create(:application, skip_proofs: true)
      )
      redeemed = create(:voucher, :redeemed, vendor: vendor, application: create(:application, skip_proofs: true))
      unassigned = create(:voucher, :active, vendor: nil, application: create(:application, skip_proofs: true))
      expected = {
        'active' => [active, expiring, unassigned],
        'expiring_soon' => [expiring],
        'redeemed' => [redeemed],
        'unassigned' => [unassigned]
      }

      expected.each do |filter, vouchers|
        get admin_vouchers_path, params: { filter: filter }
        assert_response :success
        assert_equal vouchers.map(&:code).sort, css_select('tbody tr td:first-child a').map(&:text).sort, filter
        assert_select "form input[name='filter'][value=?]", filter
      end
    end

    test 'date ranges include their day boundaries and malformed custom dates preserve status and vendor scope' do
      freeze_time do
        vendor = create(:vendor, :approved)
        dates = [Time.current.end_of_day, 1.week.ago.beginning_of_day, 1.month.ago.beginning_of_day, 1.month.ago.beginning_of_day - 1.second]
        vouchers = dates.map do |created_at|
          create(:voucher, :active, vendor: vendor, created_at: created_at, application: create(:application, skip_proofs: true))
        end
        create(:voucher, :active, vendor: create(:vendor, :approved), application: create(:application, skip_proofs: true))
        create(:voucher, :redeemed, vendor: vendor, application: create(:application, skip_proofs: true))
        expected = { 'today' => vouchers.first(1), 'week' => vouchers.first(2), 'month' => vouchers.first(3) }

        expected.each do |range, included|
          get admin_vouchers_path, params: { vendor_id: vendor.id, date_range: range }
          assert_response :success
          assert_equal included.map(&:code).sort, css_select('tbody tr td:first-child a').map(&:text).sort, range
        end

        params = { vendor_id: vendor.id, date_range: 'custom', start_date: 1.week.ago.to_date.iso8601, end_date: Date.current.iso8601 }
        get admin_vouchers_path, params: params
        assert_response :success
        assert_equal vouchers.first(2).map(&:code).sort, css_select('tbody tr td:first-child a').map(&:text).sort
        assert_select "select[name='date_range'] option[value='custom'][selected]"

        [params.merge(end_date: 'not-a-date'), params.except(:end_date)].each do |invalid_or_incomplete|
          get admin_vouchers_path, params: invalid_or_incomplete
          assert_response :success
          assert_equal vouchers.map(&:code).sort, css_select('tbody tr td:first-child a').map(&:text).sort
          assert_select "select[name='vendor_id'] option[value=?][selected]", vendor.id.to_s
        end
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
