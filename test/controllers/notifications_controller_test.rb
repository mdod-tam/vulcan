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
end
