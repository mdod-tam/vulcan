# frozen_string_literal: true

require 'test_helper'

module VendorPortal
  class DashboardControllerTest < ActionDispatch::IntegrationTest
    def setup
      # Use factory instead of fixture
      @vendor = create(:vendor, :approved)

      # Set standard test headers
      @headers = {
        'HTTP_USER_AGENT' => 'Rails Testing',
        'REMOTE_ADDR' => '127.0.0.1'
      }

      # Use the sign_in helper from test_helper.rb
      sign_in_for_integration_test(@vendor)
    end

    def test_get_show
      get vendor_portal_dashboard_path
      assert_response :success
      # Instead of checking assigns which is deprecated in newer Rails,
      # check for content in the response body that indicates the page loaded correctly
      assert_match(/dashboard/i, response.body)
    end

    test 'monthly totals chart is explicitly currency formatted' do
      get vendor_portal_dashboard_path
      assert_response :success

      assert_select '#monthly-totals-chart [data-controller="chart"][data-chart-format-value="currency"]'
    end

    test 'current month card table and chart agree across the Eastern month boundary' do
      travel_to Time.zone.local(2026, 10, 9, 12) do
        create(:voucher_transaction, vendor: @vendor, amount: 25, processed_at: Time.utc(2026, 10, 1, 3, 59, 59))
        create(:voucher_transaction, vendor: @vendor, amount: 50, processed_at: Time.utc(2026, 10, 1, 4))

        get vendor_portal_dashboard_path

        assert_response :success
        assert_select 'dl', text: /This Month's Total\s*\$50\.00/
        assert_select '#monthly-totals-table tbody tr', text: /September 2026\s*\$25\.00/
        assert_select '#monthly-totals-table tbody tr', text: /October 2026\s*\$50\.00/
        assert_select '#chart-description', text: /The highest monthly total was \$50\.00 in October 2026\./
        chart = css_select('#monthly-totals-chart [data-chart-data-value]').first
        assert_equal({ 'September 2026' => 25.0, 'October 2026' => 50.0 },
                     JSON.parse(chart['data-chart-data-value']).transform_values(&:to_f))
      end
    end

    test 'a Spanish vendor receives consistent English dashboard guidance and navigation' do
      @vendor.update!(vendor_authorization_status: :pending, locale: 'es')

      I18n.with_locale(:es) do
        get vendor_portal_dashboard_path(locale: :es)
        assert_equal :es, I18n.locale, 'the portal locale must not leak into another request'
      end

      assert_response :success
      assert_select 'html[lang="en"]'
      assert_select 'h1', 'Vendor Dashboard'
      assert_select 'nav a, header a', text: 'Profile'
      assert_select '[data-vendor-onboarding-state="awaiting_authorization"][lang="en"]' do
        assert_select 'h2', I18n.t('vendor_onboarding.states.awaiting_authorization.title', locale: :en)
        assert_select 'dt', I18n.t('vendor_onboarding.w9_label', locale: :en)
        assert_select 'dt', I18n.t('vendor_onboarding.authorization_label', locale: :en)
      end
      assert_not_includes response.body, I18n.t('vendor_onboarding.states.awaiting_authorization.title', locale: :es)
      assert_not_includes response.body, 'You are ready to redeem vouchers'
    end

    test 'the dashboard separates purchases not yet invoiced from invoices awaiting payment' do
      ensure_system_audit_actor!
      create(:voucher_transaction, vendor: @vendor, amount: 30)
      held = create(:voucher_transaction, vendor: @vendor, amount: 5)
      held.update_columns(billing_hold_at: Time.current, billing_hold_reason: 'Review')
      create(:invoice, :pending, :with_transactions, vendor: @vendor, transaction_count: 1, amount_per_transaction: 70)
      pay_invoice!(create(:invoice, :pending, :with_transactions, vendor: @vendor, transaction_count: 1, amount_per_transaction: 90))

      get vendor_portal_dashboard_path

      assert_response :success
      assert_select 'dl', text: /Not yet invoiced\s*\$30\.00/
      assert_match 'Not included: 1 voucher redemption on hold', response.body
      assert_select 'dl', text: /Invoiced, awaiting payment\s*\$70\.00/
    end
  end
end
