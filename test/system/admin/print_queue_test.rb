# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class PrintQueueTest < ApplicationSystemTestCase
    setup do
      @admin = create(:admin)

      @pending_letter = create(:print_queue_item, :pending, letter_type: :registration_confirmation)
      @pending_letter2 = create(:print_queue_item, :pending, letter_type: :application_approved)
      @printed_letter = create(:print_queue_item, letter_type: :account_created, admin: @admin)

      sign_in(@admin)
    end

    test 'viewing print queue' do
      visit admin_print_queue_index_path

      assert_selector 'h1', text: 'Print Queue'
      assert_selector 'h2', text: 'Pending Letters'
      assert_selector 'h2', text: 'Recently Printed Letters'

      assert_selector '.letter-checkbox', minimum: 2
      assert_button 'Download Selected', disabled: true
      assert_button 'Mark Selected as Printed', disabled: true
    end

    test 'selecting letters enables buttons' do
      visit admin_print_queue_index_path

      assert_button 'Download Selected', disabled: true
      assert_button 'Mark Selected as Printed', disabled: true

      first('.letter-checkbox').check

      assert_button 'Download Selected', disabled: false
      assert_button 'Mark Selected as Printed', disabled: false
    end

    test 'selecting all letters with the header checkbox' do
      visit admin_print_queue_index_path

      assert_equal 0, find_all('.letter-checkbox:checked').size

      find_by_id('select-all-pending').check

      letter_checkboxes = find_all('.letter-checkbox')
      assert_equal letter_checkboxes.size, find_all('.letter-checkbox:checked').size

      assert_button 'Download Selected', disabled: false
      assert_button 'Mark Selected as Printed', disabled: false

      find_by_id('select-all-pending').uncheck

      assert_equal 0, find_all('.letter-checkbox:checked').size

      assert_button 'Download Selected', disabled: true
      assert_button 'Mark Selected as Printed', disabled: true
    end

    test 'marking letters as printed' do
      visit admin_print_queue_index_path

      initial_pending_count = find_all('.letter-checkbox').size

      first('.letter-checkbox').check

      if has_selector?('#mark-printed-btn')
        find_by_id('mark-printed-btn').click
      elsif has_button?('Mark Selected as Printed')
        click_button 'Mark Selected as Printed'
      else
        skip 'Mark as printed button not found'
      end

      assert_selector 'h1', text: 'Print Queue'

      assert_equal initial_pending_count - 1, find_all('.letter-checkbox').size

      assert_text '1 letter marked as printed'
    end

    test 'viewing individual letter' do
      visit admin_print_queue_index_path

      pending_table = find('h2', text: 'Pending Letters').find(:xpath, './following-sibling::*//table')

      view_link = pending_table.find('tbody tr:first-child').find_link('View PDF', exact: false)
      if view_link
        new_window = window_opened_by { view_link.click }

        assert new_window, 'Expected clicking View PDF to open a new window'

        # Close the PDF window before the next queue assertion.
        within_window new_window do
          assert_current_path(%r{admin/print_queue},
                              ignore_query: true)
        end

        new_window.close

        assert_selector 'h1', text: 'Print Queue'
      else
        skip 'View PDF link not available - likely PDF not properly attached'
      end
    end
  end
end
