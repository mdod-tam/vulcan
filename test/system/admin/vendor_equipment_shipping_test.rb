# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class VendorEquipmentShippingTest < ApplicationSystemTestCase
    test 'a vendor records separate packages from the PO link without signing in' do
      ensure_system_audit_actor!
      admin = create(:admin)
      order = create(:purchase_order, vendor_name: 'Test vendor', sent_at: nil)
      first = create(:equipment_item, purchase_order: order, product: create(:product, model_number: 'Test tablet'))
      second = create(:equipment_item, purchase_order: order, application: first.application, product: create(:product, model_number: 'Test display'))

      system_test_sign_in(admin, bypass_mfa_enrollment: true)
      visit admin_purchase_order_path(order)
      assert_selector '[aria-labelledby="supplier-list-heading"] ~ #vendor-shipping'
      assert_selector '#purchase-order-device-records ~ [aria-labelledby="purchase-order-costs-title"]'
      assert_link 'Back to Purchase Orders', href: admin_purchase_orders_path
      assert_text 'Test vendor'
      find('#po-sent-date summary', text: 'Sent outside MAT?').click
      assert_field 'Actual PO sent date'
      find('#po-sent-date summary').click
      within '#vendor-shipping' do
        fill_in 'Vendor shipping email', with: 'orders@example.test'
        fill_in 'Shipping instructions (optional)', with: 'Pack the display in its original case.'
      end
      take_screenshot('po-detail-unsent', full: true, html: true)
      within '#vendor-shipping' do
        click_button 'Send PO to vendor'
      end
      assert_text 'PO link emailed to the vendor.'
      within '#vendor-shipping' do
        assert_selector 'h2', text: 'Vendor tracking link'
        assert_text 'Link expires'
        assert_button 'Revoke link'
        assert_no_field 'Vendor shipping email'
      end
      take_screenshot('po-detail-sent', full: true, html: true)
      find('#vendor-shipping summary', text: 'Email a new tracking link').click
      assert_field 'Vendor shipping email', with: 'orders@example.test'

      within("#equipment-item-#{first.id}") { click_link 'Enter shipping info' }
      assert_current_path new_admin_equipment_shipment_path, ignore_query: true
      assert_field 'Serial number', with: ''
      assert_field 'IMEI', with: ''
      assert_no_text 'Identifier not recorded'
      take_screenshot('po-staff-shipment-empty-identifiers', full: true, html: true)

      email = ActionMailer::Base.deliveries.find { |message| message.subject == "MAT purchase order #{order.number}" }
      link = Nokogiri::HTML(email.html_part.body.decoded).css('a').find { |anchor| anchor.text == 'View purchase order and enter tracking' }
      path = URI.parse(link['href']).request_uri
      system_test_sign_out
      install_stimulus_error_reporting
      visit path
      assert_text 'Pack the display in its original case.'
      assert_text first.application.user.full_name
      check 'Test tablet', exact: false
      check 'Test display', exact: false
      select 'UPS', from: 'Carrier'
      fill_in 'Tracking number', with: 'TYPED-PACKAGE'
      fill_in 'Date shipped', with: '02/30/2026'
      click_button 'Save tracking'
      assert_text 'Enter an actual shipment date.'
      assert_checked_field 'Test tablet', exact: false
      assert_checked_field 'Test display', exact: false
      assert_field 'Tracking number', with: 'TYPED-PACKAGE'
      assert_select 'Carrier', selected: 'UPS'
      uncheck 'Test display', exact: false
      select 'FedEx', from: 'Carrier'
      fill_in 'Tracking number', with: 'FIRST-PACKAGE'
      fill_in 'Date shipped', with: Date.current.strftime('%m/%d/%Y')
      click_button 'Save tracking'

      assert_text 'Tracking saved.'
      assert_text 'FIRST-PACKAGE'
      assert_unchecked_field 'Test display', exact: false
      assert_nil second.reload.shipped_at
      take_screenshot('vendor-partial-shipment', full: true, html: true)

      check 'Test display', exact: false
      select 'USPS', from: 'Carrier'
      fill_in 'Tracking number', with: 'SECOND-PACKAGE'
      fill_in 'Date shipped', with: Date.current.strftime('%m/%d/%Y')
      click_button 'Save tracking'
      assert_text 'SECOND-PACKAGE'
      assert_no_button 'Save tracking'
      assert_equal Date.current, second.reload.shipped_at
    end
  end
end
