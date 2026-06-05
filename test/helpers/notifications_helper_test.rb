# frozen_string_literal: true

require 'test_helper'

class NotificationsHelperTest < ActionView::TestCase
  include NotificationsHelper

  test 'proof resubmission notification uses rejected snapshot icon styling' do
    application = create(:application, income_proof_status: :not_reviewed)
    notification = create(
      :notification,
      notifiable: application,
      recipient: application.user,
      action: 'proof_resubmission_requested',
      metadata: { 'proof_type' => 'income', 'proof_request_display_mode' => 'rejected' }
    )

    assert_equal 'bg-red-100 text-red-500', notification_icon_classes(notification)
    assert_equal :rejected, notification_icon_type(notification)
  end

  test 'proof resubmission notification uses request styling when current proof is not rejected' do
    application = create(:application, income_proof_status: :not_reviewed)
    notification = create(
      :notification,
      notifiable: application,
      recipient: application.user,
      action: 'proof_resubmission_requested',
      metadata: { 'proof_type' => 'income', 'proof_request_display_mode' => 'requested' }
    )

    assert_equal 'bg-yellow-100 text-yellow-500', notification_icon_classes(notification)
    assert_equal :documents, notification_icon_type(notification)
  end
end
