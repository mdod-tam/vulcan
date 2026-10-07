# frozen_string_literal: true

require 'application_system_test_case'

module ConstituentPortal
  class OrdersAndShippingTest < ApplicationSystemTestCase
    setup do
      @vendor = create(:vendor, :approved, business_name: 'Accessible Phones Co')
    end

    test 'an applicant goes from the dashboard to their packages' do
      application = create(:application, status: :approved)
      record(purchase_for(application), 'AAA111')

      system_test_sign_in(application.user)
      visit constituent_portal_dashboard_path
      within('section[aria-labelledby=dashboard-orders-heading]') { click_link 'View orders and shipping' }

      assert_current_path constituent_portal_application_path(application)
      assert_selector '#orders-and-shipping', text: 'Tracking number: AAA111'
      assert_selector '#orders-and-shipping', text: 'Tracking available for 1 package'
      take_screenshot('constituent-orders-applicant', html: true, full: true)
    end

    test 'a managing guardian sees which dependent each purchase is for and reaches its packages at phone width' do
      application = create(:application, :for_dependent, status: :approved)
      record(purchase_for(application), 'BBB222')

      system_test_sign_in(application.managing_guardian)
      page.current_window.resize_to(390, 844)
      visit constituent_portal_dashboard_path
      within('section[aria-labelledby=dashboard-orders-heading]') do
        assert_text "For #{application.user.full_name}"
        click_link 'View orders and shipping'
      end

      assert_selector '#orders-and-shipping', text: 'Tracking number: BBB222'
      take_screenshot('constituent-orders-guardian-narrow', html: true, full: true)
    end

    private

    def purchase_for(application)
      voucher = create(:voucher, :active, application: application, vendor: @vendor)
      create(:voucher_transaction, voucher: voucher, vendor: @vendor, amount: 100)
    end

    def record(purchase, tracking_number)
      VoucherTransactions::FulfillmentService.new(transaction: purchase, actor: @vendor)
                                             .add_shipment!(attributes: { 'tracking_number' => tracking_number }, expected_version: 0)
    end
  end
end
