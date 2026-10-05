# frozen_string_literal: true

require 'application_system_test_case'

module VendorPortal
  class InvoicesTest < ApplicationSystemTestCase
    setup do
      @vendor_user = create(:vendor_user)

      begin
        system_test_sign_in(@vendor_user)
      rescue RuntimeError => e
        # Continue after a sign-in error only when the browser has left the sign-in page.
        raise unless e.message.include?('Sign-in failed') && current_path != sign_in_path

        debug_puts 'Sign-in helper failed after the browser left the sign-in page. Continuing test.'
      end
    end

    test 'viewing the Vendor Invoices index' do
      invoices = create_list(:invoice, 3, vendor: @vendor_user, status: 'invoice_pending')

      visit_with_retry vendor_portal_invoices_url

      assert_selector 'h1', text: 'My Invoices'

      assert_selector 'ul[role="list"] li', count: 3

      invoices.each do |invoice|
        assert_text "Invoice ##{invoice.id}"
        assert_text number_to_currency(invoice.total_amount)
        assert_text invoice.status.humanize
      end

      assert_link 'Back to Dashboard'
    end

    test 'viewing an individual Vendor Invoice' do
      invoice = create(:invoice, :paid, :with_transactions,
                       vendor: @vendor_user,
                       transaction_count: 1,
                       amount_per_transaction: 99.99,
                       gad_invoice_reference: 'GAD-TEST-REF')

      visit_with_retry vendor_portal_invoice_url(invoice)

      assert_text "Invoice ##{invoice.id}"
      assert_text number_to_currency(99.99)
      assert_text 'Paid'

      assert_not_nil invoice.gad_invoice_reference
    end

    test 'attempting to view an invoice belonging to another vendor' do
      another_vendor_user = create(:vendor_user)
      invoice_from_another_vendor = create(:invoice, vendor: another_vendor_user)

      visit_with_retry vendor_portal_invoice_url(invoice_from_another_vendor)

      assert_current_path vendor_portal_invoices_path
      assert_text 'Invoice not found'
    end

    private

    def number_to_currency(amount)
      "$#{format('%.2f', amount)}"
    end

    def visit_with_retry(url, max_retries: 3)
      retries = 0

      begin
        visit url
        page.has_selector?('body', wait: 5)
        sleep 0.5
      rescue Ferrum::PendingConnectionsError => e
        retries += 1
        if retries <= max_retries
          puts "Network error during visit, retry #{retries}/#{max_retries}: #{e.message}" if ENV['VERBOSE_TESTS']

          capture_before_browser_recovery('vendor_invoice_visit_with_retry', e) if respond_to?(:capture_before_browser_recovery)
          Capybara.reset_sessions!
          # The session reset removes authentication.
          begin
            system_test_sign_in(@vendor_user)
          rescue RuntimeError => auth_error
            # Continue after a sign-in error only when the browser has left the sign-in page.
            raise unless auth_error.message.include?('Sign-in failed') && current_path != sign_in_path

            debug_puts 'Sign-in helper failed after session reset. Browser has left the sign-in page.'
          end
          sleep 1
          retry
        else
          puts "Visit failed after #{max_retries} retries: #{e.message}" if ENV['VERBOSE_TESTS']
          puts 'Continuing test despite network error...' if ENV['VERBOSE_TESTS']
        end
      end
    end
  end
end
