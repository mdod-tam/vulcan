# frozen_string_literal: true

require 'test_helper'

class ProofAttachmentMetricsJobTest < ActiveJob::TestCase
  setup do
    Notification.delete_all
    Event.delete_all

    # Delete child rows before their parents because of foreign keys.
    ApplicationStatusChange.delete_all
    ProofReview.delete_all
    MedicalProviderSecureRequestForm.delete_all
    SecureRequestForm.delete_all
    ApplicationStatusChange.delete_all
    Application.delete_all
    GuardianRelationship.delete_all
    WebauthnCredential.delete_all
    TotpCredential.delete_all
    SmsCredential.delete_all
    Session.delete_all
    RoleCapability.delete_all
    Invoice.delete_all
    DuplicateReviewCaseCandidate.delete_all
    DuplicateReviewCase.delete_all

    # After this, the only system user and admins are the ones that setup creates.
    User.delete_all

    # User.system_user has no @system_user cache now, so this line has no effect.
    User.instance_variable_set(:@system_user, nil)

    @system_user = ensure_system_audit_actor!
    @admin1 = create(:admin)
    @admin2 = create(:admin)
    @admin3 = create(:admin)

    @application = create(:application, skip_proofs: true)
  end

  test 'creates notifications when both failure threshold and success rate conditions are met' do
    Event.delete_all
    Notification.delete_all

    base_time = Time.current

    # 6 failures: more than the minimum of 5.
    6.times do |i|
      action_name = i < 3 ? 'income_proof_attachment_failed' : 'residency_proof_attachment_failed'
      Event.create!(
        action: action_name,
        user: @application.user,
        auditable: @application,
        metadata: {
          proof_type: i < 3 ? 'income' : 'residency',
          submission_method: 'web',
          success: false,
          error_message: "Test error #{i}",
          timestamp: (base_time - (i * 2).minutes).iso8601
        },
        created_at: base_time - (i * 2).minutes
      )
    end

    # 8 successes of 14 events: a 57.1% success rate, below 95%.
    8.times do |i|
      action_name = i < 4 ? 'income_proof_attached' : 'residency_proof_attached'
      Event.create!(
        action: action_name,
        user: @application.user,
        auditable: @application,
        metadata: {
          proof_type: i < 4 ? 'income' : 'residency',
          submission_method: 'web',
          success: true,
          timestamp: (base_time - ((i + 10) * 2).minutes).iso8601
        },
        created_at: base_time - ((i + 10) * 2).minutes
      )
    end

    ProofAttachmentMetricsJob.perform_now

    expected_notifications = User.where(type: 'Users::Administrator').count
    assert expected_notifications.positive?, 'Should have administrators to notify'
    assert_equal expected_notifications, Notification.count, 'Should create one notification per administrator'

    Notification.find_each do |notification|
      assert_equal 'attachment_failure_warning', notification.action
      assert_equal 57.1, notification.metadata['success_rate']
      assert_equal 14, notification.metadata['total']
      assert_equal 6, notification.metadata['failed']
      assert notification.recipient.admin?, 'Recipient should be an admin'
    end
  end

  test "doesn't create notifications when success rate is good" do
    Notification.delete_all

    Event.where("action LIKE '%_failed'").delete_all

    ProofAttachmentMetricsJob.perform_now

    # Setup leaves no events, so the job uses its 100% default rate.
    assert_equal 0, Notification.count, 'Should not have created notifications'
  end

  test "doesn't create notifications when failure count is below threshold" do
    Event.delete_all
    Notification.delete_all

    # 4 failures: fewer than the minimum of 5.
    base_time = Time.current
    4.times do |i|
      Event.create!(
        action: 'income_proof_attachment_failed',
        user: @application.user,
        auditable: @application,
        metadata: {
          proof_type: 'income',
          submission_method: 'web',
          success: false,
          error_message: "Test error #{i}",
          timestamp: (base_time - (i * 2).minutes).iso8601
        },
        created_at: base_time - (i * 2).minutes
      )
    end

    # 6 successes of 10 events: a 60% success rate, below 95%. Only the failure minimum stops the alert.
    6.times do |i|
      Event.create!(
        action: 'income_proof_attached',
        user: @application.user,
        auditable: @application,
        metadata: {
          proof_type: 'income',
          submission_method: 'web',
          success: true,
          timestamp: (base_time - ((i + 10) * 2).minutes).iso8601
        },
        created_at: base_time - ((i + 10) * 2).minutes
      )
    end

    ProofAttachmentMetricsJob.perform_now

    assert_equal 0, Notification.count, 'Should not create notifications when failures below threshold'
  end

  test 'creates notifications when failure count meets threshold with poor success rate' do
    Event.delete_all
    Notification.delete_all

    # Exactly 5 failures: the minimum.
    base_time = Time.current
    5.times do |i|
      Event.create!(
        action: 'income_proof_attachment_failed',
        user: @application.user,
        auditable: @application,
        metadata: {
          proof_type: 'income',
          submission_method: 'web',
          success: false,
          error_message: "Test error #{i}",
          timestamp: (base_time - (i * 2).minutes).iso8601
        },
        created_at: base_time - (i * 2).minutes
      )
    end

    # 1 success of 6 events: a 16.7% success rate.
    Event.create!(
      action: 'income_proof_attached',
      user: @application.user,
      auditable: @application,
      metadata: {
        proof_type: 'income',
        submission_method: 'web',
        success: true,
        timestamp: (base_time - ((0 + 10) * 2).minutes).iso8601
      },
      created_at: base_time - ((0 + 10) * 2).minutes
    )

    ProofAttachmentMetricsJob.perform_now

    expected_notifications = User.where(type: 'Users::Administrator').count
    assert_equal expected_notifications, Notification.count, 'Should create notifications when both conditions met'

    Notification.find_each do |notification|
      assert_equal 'attachment_failure_warning', notification.action
      assert notification.metadata['success_rate'] < 95.0
      assert_equal 5, notification.metadata['failed']
      assert_equal 6, notification.metadata['total']
    end
  end

  test 'handles empty audit data' do
    Event.delete_all

    assert_nothing_raised do
      ProofAttachmentMetricsJob.perform_now
    end

    assert_equal 0, Notification.count
  end
end
