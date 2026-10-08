# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  # Letters move from awaiting release, to released (awaiting print confirmation), to printed.
  # Releasing and marking letters printed are covered in OutboundPrintControlsTest.
  class PrintQueueTest < ApplicationSystemTestCase
    setup do
      @admin = create(:admin)
      @pending_letter = create(:print_queue_item, :pending, letter_type: :registration_confirmation)
      @pending_letter2 = create(:print_queue_item, :pending, letter_type: :application_approved)
      @printed_letter = create(:print_queue_item, letter_type: :account_created, admin: @admin)

      sign_in(@admin)
    end

    test 'the queue groups letters by stage and gates release on a selection' do
      visit admin_print_queue_index_path

      assert_selector 'h1', text: 'Print Queue'
      assert_selector 'h2', text: 'Awaiting release (2)'
      assert_selector 'h2', text: 'Released — awaiting print confirmation (0)'
      assert_selector 'h2', text: 'Recently printed (1)'

      assert_button 'Release and download selected', disabled: true
      find("#letter-#{@pending_letter.id}").check
      assert_button 'Release and download selected', disabled: false
    end

    test 'each letter opens its review page' do
      visit admin_print_queue_index_path

      click_link "Review letter ##{@pending_letter.id}"

      assert_selector 'h1', text: "Letter ##{@pending_letter.id}"
    end
  end
end
