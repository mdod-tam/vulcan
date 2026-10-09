# frozen_string_literal: true

require 'application_system_test_case'

module VendorPortal
  class TransactionsTest < ApplicationSystemTestCase
    setup do
      @vendor = create(:vendor_user)
      # rubocop:disable-next FactoryBot/ExcessiveCreateList -- Exercises more than one 20-row page.
      create_list(:voucher_transaction, 23, vendor: @vendor, processed_at: Time.zone.local(2026, 10, 9, 12), amount: 40)
      system_test_sign_in(@vendor)
      install_stimulus_error_reporting
    end

    test 'date filters restore an invalid range and support correction and pagination by keyboard at phone width' do
      visit vendor_portal_dashboard_path
      click_link 'Transactions', match: :first
      assert_selector 'h1', text: 'Transaction History'
      page.current_window.resize_to(390, 844)

      select 'Custom Range', from: 'Time Period'
      assert_field 'Start Date', visible: true
      fill_in 'Start Date', with: '13/45/2026'
      fill_in 'End Date', with: '10/09/2026'
      find_field('End Date').send_keys(:enter)

      assert_selector '[role="alert"]', text: 'Start date is invalid'
      assert_field 'Start Date', with: '13/45/2026', visible: true
      assert_field 'End Date', with: '10/09/2026', visible: true
      assert_select 'Time Period', selected: 'Custom Range'
      take_screenshot('vendor-transaction-filter-error-narrow', html: true, full: true)

      # Retrying without edits leaves the same bounded result and visible error.
      click_button 'Apply Filters'
      assert_selector '[role="alert"]', text: 'Start date is invalid'
      fill_in 'Start Date', with: '10/09/2026'
      fill_in 'End Date', with: ''
      find_field('End Date').send_keys(:enter)
      assert_selector '[role="alert"]', text: 'Enter both a start date and an end date'
      assert_field 'Start Date', with: '10/09/2026', visible: true
      assert_field 'End Date', with: '', visible: true
      fill_in 'End Date', with: '10/09/2026'
      find_field('End Date').send_keys(:enter)

      assert_no_selector '[role="alert"]'
      assert_text '23 purchases totaling $920.00'
      assert_selector 'table tbody tr', count: 20
      pagination = find('nav[aria-label="Transaction pages"]')
      pagination.find('a[rel="next"]').execute_script('this.focus()')
      assert_selector 'nav[aria-label="Transaction pages"] a[rel="next"]:focus'
      page.driver.browser.keyboard.type(:enter)

      assert_selector 'nav[aria-label="Transaction pages"] [aria-current="page"]', text: '2'
      assert_selector 'table tbody tr', count: 3
      assert_field 'Start Date', with: '10/09/2026', visible: true
      assert_text '23 purchases totaling $920.00'
      take_screenshot('vendor-transaction-pagination-narrow', html: true, full: true)

      select 'All Time', from: 'Time Period'
      assert_no_selector 'input[name="start_date"]', visible: true
      select 'Custom Range', from: 'Time Period'
      assert_field 'Start Date', with: '10/09/2026', visible: true
      click_button 'Apply Filters'
      assert_selector 'nav[aria-label="Transaction pages"] [aria-current="page"]', text: '1'

      page.current_window.resize_to(1200, 800)
      take_screenshot('vendor-transaction-pagination-desktop', html: true, full: true)
    end
  end
end
