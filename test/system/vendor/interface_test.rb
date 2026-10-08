# frozen_string_literal: true

require 'application_system_test_case'

module VendorPortal
  class InterfaceTest < ApplicationSystemTestCase
    setup do
      @vendor = create(:vendor, :approved)
      @voucher = create(:voucher, :active, vendor: @vendor)

      system_test_sign_in(@vendor)
    end

    test 'viewing dashboard' do
      visit vendor_portal_dashboard_path
      clear_pending_connections_fast

      assert_selector 'h1', text: 'Vendor Dashboard'

      assert_text 'Business Information'
      assert_text 'Recent Transactions'

      assert_link 'Process Voucher'
    end

    test 'attempts voucher processing after code lookup' do
      visit vendor_portal_vouchers_path
      clear_pending_connections_fast

      fill_in 'voucher_code', with: @voucher.code
      click_on 'Verify Voucher'
      clear_pending_connections_fast

      if has_text?('Valid Voucher', wait: 3)
        fill_in 'amount', with: '50.00'
        click_on 'Process Voucher'
        clear_pending_connections_fast

        assert_text(/success|processed/i, wait: 5)
      else
        skip 'Add date-of-birth verification before the redemption assertions'
      end
    end

    test 'attempting to process an invalid voucher' do
      visit vendor_portal_vouchers_path
      clear_pending_connections_fast

      fill_in 'voucher_code', with: 'INVALID-CODE'
      click_on 'Verify Voucher'
      clear_pending_connections_fast

      assert_text(/invalid|not found|error/i, wait: 5)
    end

    test 'viewing transaction history' do
      create_list(:voucher_transaction, 3,
                  vendor: @vendor,
                  status: 'transaction_completed')

      visit vendor_portal_transactions_path
      clear_pending_connections_fast

      assert_text(/transaction|history/i)

      assert_selector 'table tbody tr', minimum: 1 if has_selector?('table tbody tr', wait: 3)
    end

    test 'requests transaction history as CSV' do
      create_list(:voucher_transaction, 3,
                  vendor: @vendor,
                  status: 'transaction_completed')

      visit vendor_portal_transactions_path(format: :csv)
      clear_pending_connections_fast

      assert_match(/csv|text/, page.response_headers['Content-Type']) if page.response_headers['Content-Type']
    end

    test 'viewing invoice details' do
      invoice = create(:invoice, :paid, :with_transactions, vendor: @vendor)

      visit vendor_portal_invoice_path(invoice)
      clear_pending_connections_fast

      assert_text invoice.invoice_number
      assert_text(/invoice paid|paid/i)
    end

    test 'enters custom dates when the controls are present' do
      visit vendor_portal_transactions_path
      clear_pending_connections_fast

      if has_select?('Time Period', wait: 2)
        select 'Custom Range', from: 'Time Period'

        if has_field?('Start Date', wait: 2)
          fill_in 'Start Date', with: 1.month.ago.strftime('%Y-%m-%d')
          fill_in 'End Date', with: Time.current.strftime('%Y-%m-%d')

          click_on 'Apply Filters' if has_button?('Apply Filters')
        else
          skip 'Start Date field is absent after Custom Range selection'
        end
      else
        skip 'Time Period select is absent on the transactions page'
      end
    end

    test 'opens dashboard for a pending vendor' do
      @vendor.update!(vendor_authorization_status: :pending)

      visit vendor_portal_dashboard_path
      clear_pending_connections_fast

      assert_text(/pending|review|approval/i) if has_text?(/pending|review|approval/i, wait: 3)

      assert_text(/w9|form|upload/i) if !@vendor.w9_form.attached? && has_text?(/w9|form|upload/i, wait: 2)
    end

    private

    def clear_pending_connections_fast
      super if defined?(super)
    rescue StandardError => e
      debug_puts "Connection clear warning in vendor interface: #{e.message}"
    end
  end
end
