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

      assert_text 'Email delivery'
      assert_selector '#email-delivery [data-email-control]', count: EmailDelivery::CONTROL_NAMES.size
      take_screenshot('email-controls-index', html: true)

      within('[data-email-control="email.category.proof"]') do
        accept_confirm(/Email waiting to be sent will be canceled/) { click_button 'Turn off' }
      end
      assert_text 'Proof is now off. Email that was waiting to be sent has been canceled.'
      within('#templates-proof-heading + ul') do
        assert_text 'Email suppressed: proof emails are turned off'
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
      assert_selector '#test-send-controls-note', text: 'Test emails follow the all-email, category, and template settings.'
      fill_in 'Recipient Email Address', with: 'tester@example.com'
      click_button 'Send Test Email'
      assert_text 'Test email not sent: this template is turned off.'
      take_screenshot('email-controls-test-send-suppressed', html: true)

      visit admin_email_templates_path
      within('[data-email-control="email.global"]') do
        accept_confirm(/including password recovery|Email waiting to be sent/) { click_button 'Turn off' }
      end
      assert_text 'All email is now off.'
      within('[data-email-control="email.category.voucher"]') do
        assert_text 'On'
        assert_text 'Email suppressed: all email is turned off'
      end
      take_screenshot('email-controls-master-off', html: true)

      page.current_window.resize_to(390, 844)
      visit admin_email_templates_path
      assert_text 'Email delivery'
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

      assert_text 'suppressed'
      assert_text 'Not sent: email was turned off in the email settings.'
      assert_no_button 'Check Status'
      take_screenshot('notification-suppressed-status', html: true)
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
      assert_text 'Print the form instead'
      assert_nil application.reload.document_signing_requested_at
      take_screenshot('docuseal-request-suppressed', html: true)
    end

    test 'turning a control back on keeps canceled email canceled and says so' do
      EmailDelivery::ControlWriter.set(name: 'email.category.proof', enabled: false, actor: @admin, operation_id: 'op-1')
      sign_in(@admin)
      visit admin_email_templates_path

      within('[data-email-control="email.category.proof"]') do
        accept_confirm(/email canceled earlier stays canceled/) { click_button 'Turn on' }
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
  end
end
