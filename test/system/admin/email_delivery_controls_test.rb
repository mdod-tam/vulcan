# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  # The email controls on the email templates page, captured at each state for review.
  class EmailDeliveryControlsTest < ApplicationSystemTestCase
    setup do
      EmailDelivery::CONTROL_NAMES.each { |name| FeatureFlag.find_or_create_by!(name: name) { |flag| flag.enabled = true } }
      load_seeded_email_templates('application_notifications_proof_approved', 'voucher_notifications_voucher_assigned')
      @admin = create(:admin)
    end

    test 'an admin turns a category, a template pair, and all email off and sees what stops' do
      sign_in(@admin)
      visit admin_email_templates_path

      assert_text 'Outgoing communications'
      assert_selector '#email-delivery [data-email-control]', count: EmailDelivery::CONTROL_NAMES.size
      within('[data-email-control="communications.global"]') do
        assert_text 'only factor is verified SMS'
        assert_text 'recovery messages for all users'
        assert_text 'SMS enrollment follows all controls.'
      end
      within('[data-email-control="communications.sms"]') { assert_text 'Off also stops sign-in codes and SMS recovery.' }
      assert_no_text 'All must be on for any channel to send.'
      take_screenshot('email-controls-index', html: true)

      within('[data-email-control="email.category.proof"]') do
        accept_confirm(/unreleased letters will be canceled permanently/) { click_button 'Turn off' }
      end
      assert_text 'Proof is now off. Matching messages and unreleased letters have been canceled.'
      within('#templates-proof-heading + ul') do
        assert_text 'Blocked: proof communications are turned off'
      end
      take_screenshot('email-controls-category-off', html: true)

      voucher_pair = "template-#{'voucher_notifications_voucher_assigned-text'.parameterize}"
      within("##{voucher_pair}") do
        accept_confirm { click_button 'Turn off' }
      end
      assert_text 'voucher_notifications_voucher_assigned (EN and ES) is now off.'
      assert_not EmailTemplate.where(name: 'voucher_notifications_voucher_assigned').any?(&:enabled)
      take_screenshot('email-controls-pair-off', html: true)

      voucher_en = EmailTemplate.find_by!(name: 'voucher_notifications_voucher_assigned', locale: 'en')
      visit new_test_email_admin_email_template_path(voucher_en)
      assert_selector '#test-send-controls-note', text: 'Test emails follow All, Email, category and template settings.'
      fill_in 'Recipient Email Address', with: 'tester@example.com'
      click_button 'Send Test Email'
      assert_text 'Test email not sent: this template is turned off.'
      take_screenshot('email-controls-test-send-suppressed', html: true)

      visit admin_email_templates_path
      within('[data-email-control="communications.global"]') do
        accept_confirm(/unreleased letters will be canceled/) { click_button 'Turn off' }
      end
      assert_text 'All outgoing communications is now off.'
      within('[data-email-control="email.category.voucher"]') do
        assert_text 'On'
        assert_text 'Blocked: all outgoing communications are turned off'
      end
      take_screenshot('email-controls-master-off', html: true)
      find('[data-email-control="communications.sms"]').scroll_to(:center)
      take_screenshot('email-controls-sms-emergency-stop', html: true)

      page.current_window.resize_to(390, 844)
      visit admin_email_templates_path
      assert_text 'Outgoing communications'
      take_screenshot('email-controls-phone-width', html: true)
    ensure
      page.current_window.resize_to(1200, 800)
    end

    test 'a notification whose email was suppressed shows that without a provider message id' do
      notification = Notification.create!(recipient: @admin, actor: @admin, action: 'medical_certification_requested',
                                          notifiable: create(:application), metadata: {})
      notification.mark_delivery_suppressed!('global_disabled')
      sign_in(@admin)
      visit notifications_path

      assert_text I18n.t('delivery_visibility.statuses.suppressed', locale: :en)
      find('[data-delivery-status="suppressed"] summary').click
      assert_text I18n.t('delivery_visibility.reasons.global_disabled', locale: :en)
      assert_no_button I18n.t('notification_delivery.check_status', locale: :en)
      take_screenshot('notification-suppressed-status', html: true)

      @admin.update!(locale: :es)
      visit notifications_path
      assert_text I18n.t('delivery_visibility.statuses.suppressed', locale: :es)
      find('[data-delivery-status="suppressed"] summary').click
      assert_text I18n.t('delivery_visibility.reasons.global_disabled', locale: :es)
      assert_no_selector '.translation_missing'
      assert_no_text 'Translation missing'
      take_screenshot('notification-suppressed-status-es', html: true)
    end

    test 'an untracked notification shows its message without a delivery panel' do
      create(:notification, recipient: @admin, actor: @admin, action: 'medical_certification_requested', notifiable: create(:application), delivery_status: nil)
      sign_in(@admin)
      visit notifications_path
      assert_text 'Disability certification requested'
      assert_no_selector '[data-delivery-status]'
      take_screenshot('notification-untracked-no-panel', html: true)
    end

    test 'a failed bulk change keeps settings and allows a fresh retry' do
      template = EmailTemplate.find_by!(name: 'voucher_notifications_voucher_assigned', locale: :en)
      before_state = EmailTemplate.order(:id).pluck(:id, :enabled, :delivery_generation)
      callback = ->(row) { raise ActiveRecord::RecordInvalid, row if row.id == template.id }
      EmailTemplate.set_callback(:update, :after, callback)
      sign_in(@admin)
      visit admin_email_templates_path

      accept_confirm { click_button 'Turn off all templates' }

      assert_text I18n.t('admin.email_delivery.bulk_failed', locale: :en)
      assert_equal before_state, EmailTemplate.order(:id).pluck(:id, :enabled, :delivery_generation)
      take_screenshot('email-controls-bulk-failure', html: true)
      EmailTemplate.skip_callback(:update, :after, callback)
      callback = nil

      accept_confirm { click_button 'Turn off all templates' }

      assert_text 'templates changed (each covers EN and ES).'
      assert EmailTemplate.deliverable.none?(&:enabled)
      take_screenshot('email-controls-bulk-retried', html: true)
    ensure
      EmailTemplate.skip_callback(:update, :after, callback) if callback
    end

    test 'a DocuSeal request while email is off explains on the page why nothing was sent' do
      application = create(:application, :in_progress, medical_provider_name: 'Dr. Provider',
                                                       medical_provider_email: 'provider@example.test')
      application.update_columns(medical_certification_status: Application.medical_certification_statuses[:not_requested])
      EmailDelivery::ControlWriter.set(name: EmailDelivery::GLOBAL_CONTROL, enabled: false, actor: @admin, operation_id: 'op-1')
      ::Docuseal.expects(:create_submission).never
      sign_in(@admin)
      visit admin_application_path(application)

      accept_confirm { click_button('Send DocuSeal Request (Default)') }

      assert_text 'Signing request not sent'
      assert_text 'Blank forms remain available'
      assert_nil application.reload.document_signing_requested_at
      take_screenshot('docuseal-request-suppressed', html: true)
    end

    test 'turning a control back on keeps canceled email canceled and says so' do
      EmailDelivery::ControlWriter.set(name: 'email.category.proof', enabled: false, actor: @admin, operation_id: 'op-1')
      sign_in(@admin)
      visit admin_email_templates_path

      within('[data-email-control="email.category.proof"]') do
        accept_confirm(/canceled messages and letters stay canceled/) { click_button 'Turn on' }
      end

      assert_text 'Proof is now on.'
      assert FeatureFlag.find_by!(name: 'email.category.proof').enabled
      take_screenshot('email-controls-category-back-on', html: true)
    end

    test 'a test email with missing settings explains the operational error' do
      FeatureFlag.find_by!(name: 'email.category.proof').destroy!
      template = EmailTemplate.find_by!(name: 'application_notifications_proof_approved', locale: 'en')
      sign_in(@admin)
      visit new_test_email_admin_email_template_path(template)
      fill_in 'Recipient Email Address', with: 'tester@example.com'
      click_button 'Send Test Email'

      assert_text I18n.t('email_delivery.configuration_error', locale: :en)
      assert_no_text 'Test email not sent: proof emails are turned off.'
      take_screenshot('email-controls-test-send-configuration-error', html: true)
    end

    test 'keyboard navigation and controls that disappear after page load remain usable' do
      sign_in(@admin)
      visit admin_email_templates_path

      30.times do
        page.driver.browser.keyboard.type(:Tab)
        break if page.evaluate_script('document.activeElement.getAttribute("href")') == '#main-content'
      end
      assert_equal '#main-content', page.evaluate_script('document.activeElement.getAttribute("href")')
      take_screenshot('email-controls-skip-link-focused', html: true)
      page.driver.browser.keyboard.type(:Enter)
      assert_equal 'main-content', page.evaluate_script('document.activeElement.id')

      %w[email.category.proof email.global].each do |name|
        FeatureFlag.find_by!(name: name).destroy!
        within("[data-email-control='#{name}']") do
          accept_confirm { click_button 'Turn off' }
        end

        assert_text 'Communication settings could not be changed because the configuration is missing or invalid.'
        within("[data-email-control='#{name}']") do
          assert_text 'Configuration error'
          assert_text 'Contact a system administrator'
          assert_no_button 'Turn on'
          assert_no_button 'Turn off'
        end
        take_screenshot("email-controls-missing-#{name.parameterize}", html: true)
      end
    end
  end
end
