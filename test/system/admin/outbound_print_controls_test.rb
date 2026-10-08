# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class OutboundPrintControlsTest < ApplicationSystemTestCase
    setup do
      @admin = create(:admin)
      @recipient = create(:constituent)
      @application = create(:application, user: @recipient)
      @letter = Letters::Delivery.queue!(recipient: @recipient, application: @application, letter_type: :medical_certification_form,
                                         context: EmailDelivery::Policy.capture(mail_action: 'Letters#medical_certification_form'), actor: @admin) do
        StringIO.new('%PDF letter')
      end
    end

    test 'All dominates saved channels and print release explains a refusal without losing history' do
      sign_in(@admin)
      visit admin_email_templates_path
      within('[data-email-control="communications.global"]') { accept_confirm { click_button 'Turn off' } }
      within('[data-email-control="communications.sms"]') do
        assert_text 'On'
        assert_text 'all outgoing communications are turned off'
      end
      take_screenshot('outbound-all-off-channel-saved-on', html: true)

      visit admin_print_queue_index_path
      assert_text 'Awaiting release'
      take_full_page_screenshot('outbound-print-queue')
      click_link "Review letter ##{@letter.id}"
      assert_text 'Release does not confirm printing or delivery'
      assert_no_selector 'iframe'
      take_full_page_screenshot('outbound-print-detail')
      click_button 'Release and download PDF'
      assert_text 'Nothing was released'
      assert_text 'Recently canceled'
      assert @letter.reload.canceled?
      assert_nil @letter.released_at
      take_full_page_screenshot('outbound-print-release-refused')

      visit admin_email_templates_path
      within('[data-email-control="communications.global"]') { accept_confirm { click_button 'Turn on' } }
      assert_text 'All outgoing communications is now on.'
      assert @letter.reload.canceled?
      @letter = Letters::Delivery.queue!(recipient: @recipient, application: @application, letter_type: :medical_certification_form,
                                         context: EmailDelivery::Policy.capture(mail_action: 'Letters#medical_certification_form'), actor: @admin) do
        StringIO.new('%PDF new letter')
      end
      visit admin_print_queue_path(@letter)
      click_button 'Release and download PDF'
      visit admin_print_queue_path(@letter)
      assert_text 'Release authorized'
      take_full_page_screenshot('outbound-print-released')
      click_button 'Mark as Printed'
      assert_text 'Letter marked as printed.'
      assert @letter.reload.printed?
      take_full_page_screenshot('outbound-print-confirmed')
    end

    test 'SMS setup preserves a refused phone number and can retry with a replacement' do
      EmailDelivery::ControlWriter.set(name: EmailDelivery::CHANNEL_CONTROLS['sms'], enabled: false,
                                       actor: @admin, operation_id: SecureRandom.uuid)
      sign_in(@admin)
      visit new_credential_two_factor_authentication_path(type: 'sms')
      fill_in 'Phone Number', with: '555-123-4567'
      click_button 'Continue'
      assert_text I18n.t('outbound_delivery.sms_suppressed')
      assert_field 'Phone Number', with: '555-123-4567'
      assert_button 'Continue', disabled: false
      take_full_page_screenshot('outbound-sms-setup-suppressed')

      EmailDelivery::ControlWriter.set(name: EmailDelivery::CHANNEL_CONTROLS['sms'], enabled: true,
                                       actor: @admin, operation_id: SecureRandom.uuid)
      fill_in 'Phone Number', with: '555-987-6543'
      click_button 'Continue'
      assert_current_path verify_pending_sms_credential_two_factor_authentication_path
      assert_no_text I18n.t('outbound_delivery.sms_suppressed')
      assert_no_text '555-123-4567'
      take_full_page_screenshot('outbound-sms-setup-retried')
    end

    test 'select all releases a batch and refreshes the queue after downloading' do
      second = Letters::Delivery.queue!(recipient: @recipient, application: @application, letter_type: :medical_certification_form,
                                        context: EmailDelivery::Policy.capture(mail_action: 'Letters#medical_certification_form'), actor: @admin) do
        StringIO.new('%PDF second letter')
      end
      sign_in(@admin)
      visit admin_print_queue_index_path
      assert_button 'Release and download selected', disabled: true
      within('section[aria-label="Awaiting release"]') do
        check 'Select all letters in Awaiting release'
        assert_selector 'input[name="letter_ids[]"]:checked', count: 2
        take_full_page_screenshot('print-batch-selected')
        click_button 'Release and download selected'
      end
      within('section[aria-label="Awaiting release"]') { assert_text 'No letters in this group.' }
      within('section[aria-label="Released — awaiting print confirmation"]') do
        assert_link "Review letter ##{@letter.id}"
        assert_link "Review letter ##{second.id}"
      end
      assert @letter.reload.released_at
      assert second.reload.released_at
      take_full_page_screenshot('print-batch-refreshed')
      page.current_window.resize_to(390, 844)
      take_full_page_screenshot('print-batch-phone')
    ensure
      page.current_window.resize_to(1200, 800)
    end

    test 'a storage failure retains the batch selection and allows a deliberate retry' do
      sign_in(@admin)
      visit admin_print_queue_index_path
      find("#letter-#{@letter.id}").check
      ActiveStorage::Blob.any_instance.stubs(:download).raises(ActiveStorage::FileNotFoundError)
      click_button 'Release and download selected'
      assert_text 'The PDF could not be prepared. Nothing was released.'
      assert_selector "#letter-#{@letter.id}:checked"
      assert_nil @letter.reload.released_at
      take_full_page_screenshot('outbound-print-storage-failure')

      ActiveStorage::Blob.any_instance.unstub(:download)
      find("#letter-#{@letter.id}").uncheck
      assert_button 'Release and download selected', disabled: true
      assert_no_selector "#letter-#{@letter.id}:checked"
      find("#letter-#{@letter.id}").check
      click_button 'Release and download selected'
      within('section[aria-label="Awaiting release"]') { assert_text 'No letters in this group.' }
      within('section[aria-label="Released — awaiting print confirmation"]') { assert_link "Review letter ##{@letter.id}" }
      take_full_page_screenshot('outbound-print-storage-retried')
    end

    test 'a released letter can be marked as printed' do
      sign_in(@admin)
      visit admin_print_queue_index_path
      within('section[aria-label="Awaiting release"]') do
        find("#letter-#{@letter.id}").check
        click_button 'Release and download selected'
      end
      within('section[aria-label="Released — awaiting print confirmation"]') do
        find("#letter-#{@letter.id}").check
        click_button 'Mark selected as printed'
      end

      assert_text 'Selected letters marked as printed.'
      within('section[aria-label="Recently printed"]') { assert_link "Review letter ##{@letter.id}" }
      assert @letter.reload.printed_at
    end

    private

    def take_full_page_screenshot(label)
      @screenshot_artifact_label = label
      wait_for_meaningful_page_content(timeout: 3)
      increment_unique
      # Persist review artifacts; these calls do not start a debugger.
      # rubocop:disable Lint/Debugger
      page.save_screenshot(image_path, full: true)
      page.save_page(image_path.sub(/\.png\z/, '.html'))
      # rubocop:enable Lint/Debugger
      write_screenshot_sidecar(image_path, label: label, html_saved: true)
      puts screenshot_log_message(image_path)
    ensure
      @screenshot_artifact_label = nil
    end
  end
end
