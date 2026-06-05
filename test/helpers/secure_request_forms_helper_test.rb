# frozen_string_literal: true

require 'test_helper'

class SecureRequestFormsHelperTest < ActionView::TestCase
  include SecureRequestFormsHelper

  test 'summary copy uses date-only sent and expiration details' do
    summary = {
      summary_status: :active,
      last_sent_at: Time.zone.local(2026, 5, 22, 15, 43),
      nearest_expiration_at: Time.zone.local(2026, 5, 24, 15, 43)
    }

    assert_equal 'Sent May 22', secure_request_summary_sent_text(summary)
    assert_equal 'Expires May 24', secure_request_summary_expiration_text(summary)
    assert_equal 'Provider info requested. Sent May 22. Expires May 24.',
                 secure_request_summary_accessible_label(summary)
  end

  test 'summary copy shows expired instead of an expired timestamp' do
    summary = {
      summary_status: :expired,
      last_sent_at: Time.zone.local(2026, 5, 22, 15, 43),
      nearest_expiration_at: Time.zone.local(2026, 5, 24, 15, 43)
    }

    assert_equal 'Expired', secure_request_summary_expiration_text(summary)
    assert_equal 'Provider info requested. Sent May 22. Expired.',
                 secure_request_summary_accessible_label(summary)
  end

  test 'summary copy shows revoked for recently revoked requests' do
    summary = {
      summary_status: :revoked,
      last_sent_at: Time.zone.local(2026, 5, 22, 15, 43),
      nearest_expiration_at: nil
    }

    assert_equal 'Revoked', secure_request_summary_expiration_text(summary)
    assert_equal 'Provider info requested. Sent May 22. Revoked.',
                 secure_request_summary_accessible_label(summary)
  end

  test 'summary copy omits expiration text when status is not visible' do
    summary = {
      summary_status: nil,
      last_sent_at: Time.zone.local(2026, 5, 22, 15, 43),
      nearest_expiration_at: nil
    }

    assert_nil secure_request_summary_expiration_text(summary)
  end

  test 'proof resubmission detail leads with rejection context when proof is rejected' do
    application = create(:application, id_proof_status: :rejected)
    admin = create(:admin)
    create(:proof_review,
           :rejected,
           application: application,
           admin: admin,
           proof_type: :id,
           rejection_reason: 'Too blurry')
    notification = create(
      :notification,
      recipient: application.user,
      actor: admin,
      notifiable: application,
      action: 'proof_resubmission_requested',
      metadata: {
        'proof_type' => 'id',
        'proof_request_display_mode' => 'rejected',
        'rejection_reason' => 'Too blurry',
        'recipient_channel' => 'email'
      }
    )

    detail = send(:secure_proof_resubmission_notification_detail, notification, notification.metadata)

    assert_includes detail, 'ID proof rejected - Too blurry; secure upload link sent to'
    assert_includes detail, 'via Email'
  end

  test 'proof resubmission detail leads with request context when proof is not rejected' do
    application = create(:application, id_proof_status: :not_reviewed)
    admin = create(:admin)
    create(:proof_review,
           :rejected,
           application: application,
           admin: admin,
           proof_type: :id,
           rejection_reason: 'Old blurry document')
    application.update!(id_proof_status: :not_reviewed)
    notification = create(
      :notification,
      recipient: application.user,
      actor: admin,
      notifiable: application,
      action: 'proof_resubmission_requested',
      metadata: {
        'proof_type' => 'id',
        'proof_request_display_mode' => 'requested',
        'recipient_channel' => 'email'
      }
    )

    detail = send(:secure_proof_resubmission_notification_detail, notification, notification.metadata)

    assert_includes detail, 'ID proof requested; secure upload link sent to'
    assert_not_includes detail, 'Old blurry document'
  end
end
