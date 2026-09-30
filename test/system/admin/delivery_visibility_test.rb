# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class DeliveryVisibilityTest < ApplicationSystemTestCase
    setup do
      @admin = create(:admin)
      @application = create(:application, :in_progress)
      @notification = create(:notification, recipient: @admin, actor: @admin, notifiable: @application,
                                            action: 'medical_certification_requested', created_at: 70.minutes.ago, metadata: { 'channel' => 'email' })
      @attempt = EmailDeliveryAttempt.create!(notification: @notification, origin: @application, application: @application,
                                              correlation_id: SecureRandom.uuid, destination: 'provider-with-long-name@example.test',
                                              recipient_key: EmailDeliveryAttempt.recipient_key('provider-with-long-name@example.test'),
                                              server_id: 'default', mail_action: 'MedicalProviderMailer#request_certification',
                                              attempted_at: 1.hour.ago, accepted_at: 1.hour.ago, delivered_at: 50.minutes.ago,
                                              bounced_at: 40.minutes.ago, bounce_category: 'HardBounce', feedback_at: 40.minutes.ago)
    end

    test 'notification details work by keyboard in English and Spanish at narrow width' do
      sign_in(@admin)
      visit notifications_path
      within("#notification_#{@notification.id}") do
        assert_text 'Bounced'
        open_details_with_keyboard(find('summary'))
        assert_text 'Permanent delivery failure'
        assert_text 'p***@example.test'
        assert_text 'Sent on'
        assert_no_text 'provider-with-long-name'
      end
      capture_delivery_screen('delivery-notification-keyboard-en')
      @admin.update!(locale: :es)
      page.current_window.resize_to(390, 844)
      visit notifications_path
      within("#notification_#{@notification.id}") do
        open_details_with_keyboard(find('summary'))
        assert_text 'Rechazado'
        assert_text 'Fallo permanente de entrega'
        assert_text 'Enviado el'
      end
      assert_no_selector '.translation_missing'
      capture_delivery_screen('delivery-notification-mobile-es')
    ensure
      page.current_window.resize_to(1200, 800)
    end

    test 'application attention links to independent request lifecycle and delivery history' do
      @application.update_columns(medical_provider_name: nil, medical_provider_email: nil)
      form = create(:secure_request_form, application: @application, recipient: @application.user, sent_at: 70.minutes.ago)
      @attempt.update!(origin: form, delivery_owner: form.delivery_owner, recipient: form.recipient)
      sign_in(@admin)
      visit admin_applications_path
      within("#application_#{@application.id}") do
        assert_link 'Delivery needs attention'
        capture_delivery_screen('delivery-application-attention')
        click_link 'Delivery needs attention'
      end
      assert_current_path admin_application_path(@application), ignore_query: true
      assert_selector '[data-delivery-status="bounced"]', minimum: 1
      open_details_with_keyboard(find('[aria-labelledby="secure-request-forms-title"] [data-delivery-status="bounced"] summary'))
      assert_text 'Requested on'
      assert_text 'Bounced'
      assert_predicate form.reload, :active?
      capture_delivery_screen('delivery-application-request-history')
    end

    private

    def capture_delivery_screen(label)
      @screenshot_artifact_label = label
      page.execute_script('window.scrollTo(0, 0)')
      increment_unique
      # rubocop:disable Lint/Debugger -- Required browser evidence artifacts.
      page.save_screenshot(image_path, full: true)
      page.save_page(image_path.sub(/\.png\z/, '.html'))
      # rubocop:enable Lint/Debugger
      write_screenshot_sidecar(image_path, label: label, html_saved: true)
      puts screenshot_log_message(image_path)
    ensure
      @screenshot_artifact_label = nil
    end

    def open_details_with_keyboard(summary)
      # Cuprite's element.send_keys clicks first, which would toggle details twice.
      summary.execute_script('this.focus()')
      assert summary.matches_css?(':focus')
      page.driver.browser.keyboard.type(:enter)
    end
  end
end
