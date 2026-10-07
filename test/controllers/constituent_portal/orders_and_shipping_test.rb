# frozen_string_literal: true

require 'test_helper'

module ConstituentPortal
  # Orders and shipping on the application page and the dashboard. Both list purchases through
  # VoucherTransaction.purchases_visible_to, so only the applicant of an unmanaged application or the
  # application's managing guardian sees them.
  class OrdersAndShippingTest < ActionDispatch::IntegrationTest
    setup do
      @vendor = create(:vendor, :approved, business_name: 'Accessible Phones Co')
    end

    test 'the applicant sees each purchase with its packages, vendor, and program support' do
      application = create(:application, status: :approved)
      purchase = purchase_for(application)
      record(purchase, 'AAA111', dispatched_on: Date.new(2026, 9, 9), contents: 'Phone')
      record(purchase, 'BBB222')

      sign_in_for_integration_test(application.user)
      get constituent_portal_application_path(application)

      assert_response :success
      assert_select 'section#orders-and-shipping[aria-labelledby=orders-heading]' do
        assert_select 'h2', 'Orders and shipping'
        assert_select 'li', text: /Accessible Phones Co/
        assert_select 'span', text: 'Tracking available for 2 packages'
        assert_select 'li', text: /Tracking number: AAA111/
        assert_select 'li', text: /Vendor-reported ship date: September 09, 2026/
        assert_select 'li', text: /Contents: Phone/
        assert_select 'li', text: /Tracking number: BBB222/
        assert_select 'p', text: /Contact Accessible Phones Co, or the MAT program at #{ProgramContact.support_email}/
      end
    end

    test 'a purchase with no packages yet is not described as shipped' do
      application = create(:application, status: :approved)
      purchase_for(application)

      sign_in_for_integration_test(application.user)
      get constituent_portal_application_path(application)

      assert_select '#orders-and-shipping span', text: 'Waiting for shipping details'
      assert_select '#orders-and-shipping', text: /Tracking available/, count: 0
    end

    test 'the managing guardian sees the dependent\'s purchases on the application page and dashboard' do
      application = create(:application, :for_dependent, status: :approved)
      record(purchase_for(application), 'AAA111')
      guardian = application.managing_guardian

      sign_in_for_integration_test(guardian)
      get constituent_portal_application_path(application)
      assert_select '#orders-and-shipping li', text: /AAA111/

      get constituent_portal_dashboard_path
      assert_response :success
      assert_select 'section[aria-labelledby=dashboard-orders-heading]' do
        assert_select 'li', text: /For #{application.user.full_name}/
        assert_select "a[href='#{constituent_portal_application_path(application, anchor: 'orders-and-shipping')}']",
                      text: 'View orders and shipping'
      end
    end

    test 'a guardian who does not manage the application, and an unrelated constituent, see none of it' do
      application = create(:application, :for_dependent, status: :approved)
      record(purchase_for(application), 'AAA111')
      other_guardian = create(:constituent)
      create(:guardian_relationship, guardian_user: other_guardian, dependent_user: application.user)

      [other_guardian, create(:constituent), application.user].each do |user|
        sign_in_for_integration_test(user)

        get constituent_portal_application_path(application)
        assert_redirected_to constituent_portal_dashboard_path, "#{user.email} should not open the application"

        get constituent_portal_dashboard_path
        assert_select 'section[aria-labelledby=dashboard-orders-heading]', count: 0
        assert_no_match(/AAA111|Accessible Phones Co/, response.body)
        sign_out
      end
    end

    test 'an application without vouchers shows no orders section' do
      application = create(:application, status: :approved)

      sign_in_for_integration_test(application.user)
      get constituent_portal_application_path(application)

      assert_select '#orders-and-shipping', count: 0
    end

    private

    def purchase_for(application)
      voucher = create(:voucher, :active, application: application, vendor: @vendor)
      create(:voucher_transaction, voucher: voucher, vendor: @vendor, amount: 100)
    end

    def record(purchase, tracking_number, **attributes)
      VoucherTransactions::FulfillmentService.new(transaction: purchase, actor: @vendor).add_shipment!(
        attributes: { 'tracking_number' => tracking_number }.merge(attributes.stringify_keys),
        expected_version: purchase.reload.fulfillment_version
      )
    end
  end
end
