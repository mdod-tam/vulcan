# frozen_string_literal: true

require 'application_system_test_case'

class NotificationDeliveryVisibilityTest < ApplicationSystemTestCase
  setup do
    @constituent = create(:constituent)
    @application = create(:application, :in_progress, user: @constituent)
    @notification = create(:notification, recipient: @constituent, notifiable: @application,
                                          action: 'proof_approved', metadata: { 'proof_type' => 'income' })
    @notification.email_delivery_attempts.create!(
      origin: @application, application: @application, correlation_id: SecureRandom.uuid,
      destination: @constituent.email, recipient_key: EmailDeliveryAttempt.recipient_key(@constituent.email),
      delivery_owner: @constituent, server_id: '23', provider_message_id: 'recipient-tracked-message',
      mail_action: 'ApplicationNotificationsMailer#proof_approved', attempted_at: 2.hours.ago, accepted_at: 2.hours.ago,
      opened_at: 1.hour.ago
    )
    @suppressed = create(:notification, recipient: @constituent, notifiable: @application,
                                        action: 'proof_approved', metadata: { 'proof_type' => 'income' })
    @suppressed.mark_delivery_suppressed!('all_disabled', channel: :email)
    @other_notification = create(:notification, recipient: create(:constituent))
  end

  test 'recipient sees owned statuses without diagnostics before and after marking a notification read' do
    sign_in(@constituent)
    visit notifications_path(scope: 'all')

    assert_recipient_statuses('Sent — awaiting confirmation', 'Not sent')
    assert_no_selector "#notification_#{@other_notification.id}"
    capture_recipient_screen('delivery-recipient-statuses-en')

    within("#notification_#{@notification.id}") do
      click_button 'Mark as read'
      assert_no_button 'Mark as read'
    end
    assert_not_nil @notification.reload.read_at
    assert_recipient_statuses('Sent — awaiting confirmation', 'Not sent')
    capture_recipient_screen('delivery-recipient-read-replacement-en')
  end

  test 'Spanish recipient statuses remain usable at narrow width without operational controls' do
    @constituent.update!(locale: :es)
    sign_in(@constituent)
    page.current_window.resize_to(390, 844)
    visit notifications_path(scope: 'all')

    assert_recipient_statuses('Enviado — esperando confirmación', 'No enviado')
    assert_no_selector "#notification_#{@other_notification.id}"
    assert_no_selector '.translation_missing'
    capture_recipient_screen('delivery-recipient-statuses-mobile-es')

    within("#notification_#{@notification.id}") do
      click_button 'Marcar como leída'
      assert_no_button 'Marcar como leída'
    end
    assert_not_nil @notification.reload.read_at
    assert_recipient_statuses('Enviado — esperando confirmación', 'No enviado')
    capture_recipient_screen('delivery-recipient-read-replacement-mobile-es')
  ensure
    page.current_window.resize_to(1200, 800)
  end

  private

  def assert_recipient_statuses(accepted_label, suppressed_label)
    within("#notification_#{@notification.id} [data-delivery-status='accepted']") do
      assert_text accepted_label
      assert_no_selector 'details', visible: :all
      assert_no_selector 'summary', visible: :all
      assert_no_text @constituent.email, exact: false
      assert_no_text(/Open detected|Apertura detectada|Last checked|Última comprobación/)
    end
    within("#notification_#{@suppressed.id} [data-delivery-status='suppressed']") do
      assert_text suppressed_label
      assert_no_selector 'details', visible: :all
      assert_no_text(/Delivery controls|controles de entrega/)
    end
    assert_no_selector "form[action='#{check_email_status_notification_path(@notification)}']", visible: :all
    assert_no_selector "form[action='#{check_email_status_notification_path(@suppressed)}']", visible: :all
  end

  def capture_recipient_screen(label)
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
end
