# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class OutboundPrintControlsTest < ApplicationSystemTestCase
    setup do
      @admin = create(:admin)
      @recipient = create(:constituent)
      @application = create(:application, user: @recipient)
      @letter = Letters::Delivery.queue!(recipient: @recipient, application: @application, letter_type: :disability_certification_form,
                                         context: EmailDelivery::Policy.capture(mail_action: 'Letters#disability_certification_form'), actor: @admin) do
        StringIO.new('%PDF letter')
      end
    end

    test 'All dominates saved channels and blocked letters remain visible without being selectable' do
      sign_in(@admin, bypass_mfa_enrollment: true)
      visit admin_email_templates_path
      within('[data-email-control="communications.global"]') { accept_confirm { click_button 'Turn off outgoing correspondence' } }
      within('[data-email-control="communications.sms"]') do
        assert_text 'Saved on'
        assert_text 'Blocked by master'
      end
      take_screenshot('outbound-all-off-channel-saved-on', html: true)

      visit admin_print_queue_index_path
      assert_text 'Awaiting release'
      take_full_page_screenshot('outbound-print-queue')
      click_link "Review letter ##{@letter.id}"
      assert_text 'Current mailing address'
      assert_text 'Outgoing correspondence is turned off'
      assert_no_button 'Release and download PDF'
      assert_no_selector 'iframe'
      take_full_page_screenshot('outbound-print-detail')
      click_link 'Back to print queue'
      within('section[aria-labelledby="print-attention-heading"]') do
        assert_link "Review letter ##{@letter.id}"
        assert_text 'Outgoing correspondence is turned off'
      end
      assert_no_selector "#letter-#{@letter.id}"
      Letters::ReconcilePendingJob.perform_now
      refresh
      within('section[aria-label="Recently canceled"]') { assert_link "Review letter ##{@letter.id}" }
      assert @letter.reload.canceled?
      assert_nil @letter.released_at
      take_full_page_screenshot('outbound-print-release-refused')

      visit admin_email_templates_path
      within('[data-email-control="communications.global"]') { accept_confirm { click_button 'Resume outgoing correspondence' } }
      assert_text 'Outgoing correspondence is now on.'
      assert @letter.reload.canceled?
      @letter = Letters::Delivery.queue!(recipient: @recipient, application: @application, letter_type: :disability_certification_form,
                                         context: EmailDelivery::Policy.capture(mail_action: 'Letters#disability_certification_form'), actor: @admin) do
        StringIO.new('%PDF new letter')
      end
      visit admin_print_queue_path(@letter)
      click_button 'Release and download PDF'
      assert_button 'Mark as Printed'
      assert_text 'Awaiting print confirmation'
      take_full_page_screenshot('outbound-print-released')
      click_button 'Mark as Printed'
      assert_text 'Letter marked as printed.'
      assert @letter.reload.printed?
      take_full_page_screenshot('outbound-print-confirmed')
    end

    test 'a released letter can be canceled after the download and disappears from pending work' do
      sign_in(@admin, bypass_mfa_enrollment: true)
      visit admin_dashboard_path
      assert_link 'View print queue'
      take_full_page_screenshot('print-queue-dashboard')
      click_link 'View print queue'
      click_link "Review letter ##{@letter.id}"
      click_button 'Release and download PDF'
      assert_button 'Mark as Printed'
      page.current_window.resize_to(390, 844)
      take_full_page_screenshot('print-letter-released-phone')

      accept_confirm(/Discard unused copies/) { click_button 'Cancel letter' }
      assert_text 'Letter canceled.'
      assert_no_button 'Mark as Printed'
      assert_text 'Released:'
      take_full_page_screenshot('print-letter-canceled')

      click_link 'Back to print queue'
      within('section[aria-label="Released — awaiting print confirmation"]') { assert_no_link "Review letter ##{@letter.id}" }
      within('section[aria-label="Recently canceled"]') { assert_link "Review letter ##{@letter.id}" }
    ensure
      page.current_window.resize_to(1200, 800)
    end

    test 'staff can stage a scanned proof returned by mail after the secure token expires' do
      recipient = Current.set(paper_context: true) do
        create(:constituent, email: nil, phone: nil, communication_preference: :letter)
      end
      application = create(:application, user: recipient, status: :awaiting_proof)
      result = Applications::RequestProofResubmission.new(application: application, actor: @admin, proof_type: :id).call
      assert_predicate result, :success?
      form = result.data.fetch(:secure_request_forms).sole
      letter = form.print_queue_items.sole

      travel_to form.sent_at + 72.hours do
        sign_in(@admin, bypass_mfa_enrollment: true)
        visit admin_print_queue_path(letter)
        assert_text 'ID proof request'
        click_button 'Release and download PDF'
        assert_text 'Awaiting print confirmation'
        take_full_page_screenshot('expired-paper-request-released')
        accept_confirm(/Discard unused copies/) { click_button 'Replace paper request' }
        assert_text 'Replacement letter queued.'
        assert_text 'Canceled'
        assert_no_button 'Mark as Printed'
        take_full_page_screenshot('expired-paper-request-replaced')
      end

      replacement = application.secure_request_forms.where(revoked_at: nil).sole
      travel_to replacement.sent_at + 7.days do
        SecureFormExpirationRecorder.new.call
        sign_in(@admin, bypass_mfa_enrollment: true)
        replacement_letter = replacement.print_queue_items.sole
        visit admin_print_queue_path(replacement_letter)
        click_button 'Release and download PDF'
        assert_button 'Mark as Printed'
        visit admin_application_path(application)
        assert_selector '#mailed-id-document[aria-describedby~="mailed-id-formats"]'
        assert_selector '#mailed-id-formats', text: /up to/
        within "#secure_request_form_#{form.id}" do
          assert_text 'Letter canceled', count: 1
          assert_no_text 'canceled before release'
          assert_text 'No link'
        end
        within '#audit-logs' do
          assert_text 'Paper proof request'
          assert_text "Paper response requested from #{recipient.full_name}"
          assert_no_text 'secure upload link sent'
          assert_no_text 'Proof Resubmission Request Expired'
        end
        take_full_page_screenshot('mailed-proof-upload')
        attach_cleared_document 'mailed-id-document', file_fixture('id_proof.pdf')
        click_button 'Upload for review'
        assert_text 'Mailed proof uploaded for review.'
        assert application.reload.id_proof.attached?
        assert_not replacement.reload.postal_delivery_eligible?
        within "#secure_request_form_#{replacement.id}" do
          assert_text 'Request closed. Do not mail this copy.'
          assert_text 'Letter released', count: 1
        end
        take_full_page_screenshot('mailed-proof-recorded')
        click_link "Review letter ##{replacement_letter.id}"
        assert_text 'Resolve downloaded copy'
        take_screenshot('closed-request-downloaded-copy', html: true)
        accept_confirm { click_button 'Discard unused copy' }
        assert_text 'Letter canceled.'
        assert_predicate replacement_letter.reload, :canceled?
      end
    end

    test 'staff can find the failed rejection letter receipt and record manual mailing' do
      receipt = NotificationService.create_and_deliver!(
        type: Notification::PAPER_REJECTION_LETTER_ACTION, recipient: @admin, actor: @admin, notifiable: @recipient, deliver: false, channel: :letter
      )
      receipt.record_delivery_queued!
      sign_in(@admin, bypass_mfa_enrollment: true)
      visit notifications_path
      within("#notification_#{receipt.id}") { click_link "Income rejection letter for #{@recipient.full_name}" }
      assert_text 'Waiting for PDF'
      receipt.mark_delivery_not_sent!(EmailDelivery::Decision.configuration_error(:unsupported_letter_text), channel: :letter)
      click_link 'Refresh status'
      assert_text 'Letter not queued'
      assert_text 'Prepare and mail this letter by hand.'
      take_screenshot('paper-rejection-letter-failed', html: true)
      accept_confirm { click_button 'Record as mailed' }
      assert_text 'Mailed by hand'
      assert_no_button 'Record as mailed'
      take_screenshot('paper-rejection-letter-mailed', html: true)
    end

    test 'SMS setup preserves a refused phone number and can retry with a replacement' do
      EmailDelivery::ControlWriter.set(name: EmailDelivery::CHANNEL_CONTROLS['sms'], enabled: false,
                                       actor: @admin, operation_id: SecureRandom.uuid)
      sign_in(@admin, bypass_mfa_enrollment: true)
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

    test 'select all keeps the exact batch together after downloading' do
      second = Letters::Delivery.queue!(recipient: @recipient, application: @application, letter_type: :disability_certification_form,
                                        context: EmailDelivery::Policy.capture(mail_action: 'Letters#disability_certification_form'), actor: @admin) do
        StringIO.new('%PDF second letter')
      end
      sign_in(@admin, bypass_mfa_enrollment: true)
      visit admin_print_queue_index_path
      assert_button 'Release and download selected', disabled: true
      within('section[aria-label="Awaiting release"]') do
        check 'Select all letters in Awaiting release'
        assert_selector 'input[name="letter_ids[]"]:checked', count: 2
        take_full_page_screenshot('print-batch-selected')
        click_button 'Release and download selected'
      end
      assert_selector 'h1', text: 'Print batch'
      within('section[aria-label="Batch letters"]') do
        assert_selector 'input[name="letter_ids[]"]:checked', count: 2
        assert_link "Review letter ##{@letter.id}"
        assert_link "Review letter ##{second.id}"
        assert_button 'Mark 2 printed'
      end
      assert @letter.reload.released_at
      assert second.reload.released_at
      take_full_page_screenshot('print-batch-refreshed')
      page.current_window.resize_to(390, 844)
      assert page.evaluate_script('document.documentElement.scrollWidth <= window.innerWidth')
      take_full_page_screenshot('print-batch-phone')
    ensure
      page.current_window.resize_to(1200, 800)
    end

    test 'a storage failure retains the batch selection and allows a deliberate retry' do
      sign_in(@admin, bypass_mfa_enrollment: true)
      visit admin_print_queue_index_path
      find("#letter-#{@letter.id}").check
      ActiveStorage::Blob.any_instance.stubs(:download).raises(IOError)
      click_button 'Release and download selected'
      assert_text 'Couldn’t prepare the PDF. Nothing was released.'
      assert_selector "#letter-#{@letter.id}:checked"
      assert_nil @letter.reload.released_at
      take_full_page_screenshot('outbound-print-storage-failure')

      ActiveStorage::Blob.any_instance.unstub(:download)
      find("#letter-#{@letter.id}").uncheck
      assert_button 'Release and download selected', disabled: true
      assert_no_selector "#letter-#{@letter.id}:checked"
      find("#letter-#{@letter.id}").check
      click_button 'Release and download selected'
      within('section[aria-label="Batch letters"]') { assert_link "Review letter ##{@letter.id}" }
      take_full_page_screenshot('outbound-print-storage-retried')
    end

    test 'a released letter can be marked as printed' do
      sign_in(@admin, bypass_mfa_enrollment: true)
      visit admin_print_queue_index_path
      within('section[aria-label="Awaiting release"]') do
        find("#letter-#{@letter.id}").check
        click_button 'Release and download selected'
      end
      within('section[aria-label="Batch letters"]') do
        assert_selector "#letter-#{@letter.id}:checked"
        click_button 'Mark 1 printed'
      end

      assert_text 'Selected letters marked as printed.'
      within('section[aria-label="Batch letters"]') { assert_text 'Printed' }
      assert @letter.reload.printed_at
    end

    test 'a keyboard user can leave out an unsafe copy and record outgoing mail once' do
      ensure_system_audit_actor!
      context = EmailDelivery::Policy.capture(mail_action: 'ApplicationNotificationsMailer#account_created')
      letters = [@recipient, create(:constituent)].map do |recipient|
        Letters::Delivery.queue!(recipient: recipient, application: nil, letter_type: :account_created, context: context) do
          StringIO.new('%PDF letter')
        end
      end
      first, stale = letters
      sign_in(@admin, bypass_mfa_enrollment: true)
      visit admin_print_queue_index_path
      letters.each { |letter| find("#letter-#{letter.id}").check }
      click_button 'Release and download selected'
      assert_button 'Mark 2 in outgoing mail'
      stale.constituent.update!(physical_address_1: '76 New Street')
      refresh
      page.current_window.resize_to(390, 844)
      assert_text 'Do not mail.'
      assert_selector "#letter-#{stale.id}[aria-describedby='mail_warning_print_queue_item_#{stale.id}']"
      assert_button 'Mark 2 in outgoing mail', disabled: true
      take_full_page_screenshot('print-batch-do-not-mail-phone')

      page.execute_script("document.getElementById('letter-#{stale.id}').focus()")
      page.driver.browser.keyboard.type(:Space)
      assert_selector "#letter-#{first.id}:checked"
      assert_button 'Mark 1 in outgoing mail', disabled: false
      click_button 'Mark 1 in outgoing mail'

      assert_text 'Marked in outgoing mail.'
      assert first.reload.mail_handoff_at?
      assert_predicate stale.reload, :pending?
      assert_no_selector "#letter-#{stale.id}:checked"
      take_full_page_screenshot('print-batch-mail-recorded')
    ensure
      page.current_window.resize_to(1200, 800)
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
