# frozen_string_literal: true

require 'application_system_test_case'

module VendorPortal
  class ShipmentsTest < ApplicationSystemTestCase
    setup do
      @vendor = create(:vendor_user)
      @purchase = create(:voucher_transaction, vendor: @vendor)
      system_test_sign_in(@vendor)
      install_stimulus_error_reporting
    end

    test 'a vendor finds a purchase needing details, fixes a rejected entry by keyboard at phone width, and corrects it' do
      visit vendor_portal_transactions_path
      check 'Only purchases that need shipping details'
      click_button 'Apply Filters'
      assert_text 'Waiting for shipping details'
      click_link "View purchase #{@purchase.reference_number}"
      assert_selector 'h1', text: "Purchase #{@purchase.reference_number}"

      page.current_window.resize_to(390, 844)
      fill_in 'Tracking number', with: '1Z 999 AA1'
      fill_in 'Ship date (optional)', with: '13/45/2026'
      find_field('Ship date (optional)').send_keys(:enter)

      assert_selector '#new_shipment_errors:focus', text: 'Ship date is not a valid date'
      assert_field 'Ship date (optional)', with: '13/45/2026'
      assert_field 'Tracking number', with: '1Z 999 AA1'
      assert_empty @purchase.shipments
      take_screenshot('vendor-shipment-validation-narrow', html: true, full: true)

      find('#new_shipment_errors a').execute_script('this.focus()')
      page.driver.browser.keyboard.type(:enter)
      assert_selector '#new_shipment_shipment_dispatched_on:focus'
      page.driver.browser.keyboard.type(:end, *Array.new('13/45/2026'.length, :backspace), '9/9/2026', :enter)

      assert_text 'Tracking number saved'
      assert_text 'Tracking available for 1 package'
      shipment = @purchase.shipments.sole
      assert_equal Date.new(2026, 9, 9), shipment.dispatched_on
      take_screenshot('vendor-shipment-saved-narrow', html: true)

      page.current_window.resize_to(1200, 800)
      find('summary', text: 'Correct this package').click
      fill_in "shipment_#{shipment.id}_shipment_tracking_number", with: '1Z 999 AA2'
      click_button 'Save correction'

      assert_text 'Package updated.'
      assert_text '1Z 999 AA2'
      assert_text 'Tracking available for 1 package'
      assert_equal '1Z 999 AA2', shipment.reload.tracking_number
      take_screenshot('vendor-shipment-corrected', html: true)
    end
  end
end
