# frozen_string_literal: true

require 'test_helper'

class NotificationsControllerTest < ActionDispatch::IntegrationTest
  include AuthenticationTestHelper

  setup do
    @user = create(:constituent)
    @other_user = create(:constituent)
    @notification = create(:notification, recipient: @user)
    @other_notification = create(:notification, recipient: @other_user)
  end

  test 'Spanish notification outcomes and controls use channel-neutral localized text' do
    @user.update!(locale: :es)
    @notification.mark_delivery_suppressed!('channel_disabled', channel: :sms)
    sign_in_for_integration_test(@user)

    get notifications_path

    assert_response :success
    assert_select "#notification_#{@notification.id}", text: /No enviado/
    assert_select "#notification_#{@notification.id} [data-delivery-status='suppressed'] span", text: 'No enviado'
    assert_select "#notification_#{@notification.id} details", count: 0
    assert_select "#notification_#{@notification.id}", text: /Los controles de entrega/, count: 0
    assert_select "#notification_#{@notification.id} button", text: 'Marcar como leída'
    assert_select "#notification_#{@notification.id}", text: /suppressed|Mark as read|correo estaba desactivado/, count: 0
    assert_select '.translation_missing', count: 0

    [3.hours.ago, 40.days.ago, 3.years.ago].each do |created_at|
      @notification.update!(created_at: created_at)
      get notifications_path

      assert_response :success
      assert_select '.translation_missing', count: 0
      assert_select "#notification_#{@notification.id} p", text: /Hace/
    end
  end

  test 'user can mark their own notification as read' do
    sign_in_for_integration_test(@user)

    post mark_as_read_notification_path(@notification)

    assert_redirected_to notifications_path
    assert_not_nil @notification.reload.read_at
  end

  test 'user cannot mark another users notification as read' do
    sign_in_for_integration_test(@user)

    post mark_as_read_notification_path(@other_notification)

    assert_redirected_to root_path
    assert_nil @other_notification.reload.read_at
  end

  test 'user cannot check another users email status' do
    sign_in_for_integration_test(@user)
    @other_notification.update!(message_id: 'postmark-message-id')

    assert_no_enqueued_jobs only: UpdateEmailStatusJob do
      post check_email_status_notification_path(@other_notification)
    end

    assert_response :forbidden
  end

  test 'constituents cannot refresh their own tracked notifications by HTML or Turbo requests' do
    create_tracked_attempt
    sign_in_for_integration_test(@user)

    [nil, 'text/vnd.turbo-stream.html'].each do |accept|
      assert_no_enqueued_jobs only: UpdateEmailStatusJob do
        post check_email_status_notification_path(@notification), headers: accept ? { 'Accept' => accept } : {}
      end
      assert_response :forbidden
    end
  end

  test 'constituent list and mark-read replacement contain basic status without diagnostics or refresh' do
    create_tracked_attempt
    sign_in_for_integration_test(@user)

    get notifications_path(scope: 'all')

    assert_select "#notification_#{@notification.id} [data-delivery-status='accepted']", count: 1
    assert_select "#notification_#{@other_notification.id}", count: 0
    assert_recipient_delivery_visibility

    post mark_as_read_notification_path(@notification), headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

    assert_response :success
    assert_select "turbo-stream[action='replace'][target='notification_#{@notification.id}']", count: 1
    assert_select "#notification_#{@notification.id} [data-delivery-status='accepted']", count: 1
    assert_recipient_delivery_visibility
    assert_not_nil @notification.reload.read_at
  end

  test 'admin retains delivery details and can refresh a recipients tracked notification' do
    create_tracked_attempt
    sign_in_for_integration_test(create(:admin))

    get notifications_path

    assert_select "#notification_#{@notification.id} summary", count: 1
    assert_select "form[action='#{check_email_status_notification_path(@notification)}']", count: 1
    assert_enqueued_with(job: UpdateEmailStatusJob, args: [@notification.id]) do
      post check_email_status_notification_path(@notification)
    end
    assert_redirected_to root_path
  end

  test 'admin can act on any notification' do
    admin = create(:admin)
    sign_in_for_integration_test(admin)

    post mark_as_read_notification_path(@other_notification)

    assert_redirected_to notifications_path
    assert_not_nil @other_notification.reload.read_at
  end

  test 'constituent notifications index uses constituent-safe links' do
    application = create(:application, user: @user)
    create(:notification,
           recipient: @user,
           actor: create(:admin),
           notifiable: application,
           action: 'proof_approved',
           metadata: { 'proof_type' => 'income' })

    sign_in_for_integration_test(@user)
    get notifications_path

    assert_response :success
    assert_select 'a[href=?]', constituent_portal_dashboard_path, text: 'Back to Dashboard'
    assert_select 'a[href=?]', constituent_portal_application_path(application), text: /Application ##{application.id}/
    assert_select 'a[href=?]', admin_application_path(application), count: 0
  end

  private

  def create_tracked_attempt
    @notification.email_delivery_attempts.create!(
      correlation_id: SecureRandom.uuid, destination: @user.email,
      recipient_key: EmailDeliveryAttempt.recipient_key(@user.email), delivery_owner: @user,
      server_id: '23', provider_message_id: 'tracked-message', mail_action: 'UserMailer#password_reset',
      attempted_at: 2.hours.ago, accepted_at: 2.hours.ago
    )
  end

  def assert_recipient_delivery_visibility
    assert_select "#notification_#{@notification.id} details", count: 0
    assert_select "form[action='#{check_email_status_notification_path(@notification)}']", count: 0
    assert_select "#notification_#{@notification.id}", text: /Contact owner:|Destination:|Last checked:|Open detected/, count: 0
  end
end
