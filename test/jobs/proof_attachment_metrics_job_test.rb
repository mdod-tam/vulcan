# frozen_string_literal: true

require 'test_helper'

class ProofAttachmentMetricsJobTest < ActiveJob::TestCase
  setup do
    # Clear all notifications and events for a clean slate
    Notification.delete_all
    Event.delete_all

    # Clear dependent records first to avoid foreign key violations
    ProofReview.delete_all
    ApplicationStatusChange.delete_all
    Application.delete_all
    GuardianRelationship.delete_all
    WebauthnCredential.delete_all
    TotpCredential.delete_all
    SmsCredential.delete_all
    Session.delete_all
    RoleCapability.delete_all
    Invoice.delete_all

    # Clear all users to ensure a completely clean slate for system_user and admins
    User.delete_all

    # Clear the cached system user to prevent stale references
    User.instance_variable_set(:@system_user, nil)

    # Create the system user and some test administrators
    @system_user = User.system_user # This will create it if it doesn't exist
    @admin1 = create(:admin)
    @admin2 = create(:admin)
    @admin3 = create(:admin)

    # Create test application for use in tests
    @application = create(:application, skip_proofs: true)
  end

  test 'creates notifications when both failure threshold and success rate conditions are met' do
    # Clear all events and notifications for a clean slate
    Event.delete_all
    Notification.delete_all

    # Create a scenario that meets both conditions:
    # 1. At least 5 failures (threshold condition)
    # 2. Success rate below 95% (success rate condition)
    base_time = Time.current

    # Create 6 failure events (above threshold of 5)
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

    # Create 8 successful events to get 57.1% success rate (8 successes / 14 total)
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

    # Run the job
    ProofAttachmentMetricsJob.perform_now

    # Should create notifications for all administrators
    expected_notifications = User.where(type: 'Users::Administrator').count
    assert expected_notifications.positive?, 'Should have administrators to notify'
    assert_equal expected_notifications, Notification.count, 'Should create one notification per administrator'

    # Check that each notification has the correct content
    Notification.find_each do |notification|
      assert_equal 'attachment_failure_warning', notification.action
      assert_equal 57.1, notification.metadata['success_rate']
      assert_equal 14, notification.metadata['total']
      assert_equal 6, notification.metadata['failed']
      assert notification.recipient.admin?, 'Recipient should be an admin'
    end
  end

  test "doesn't create notifications when success rate is good" do
    # Ensure clean state before test
    Notification.delete_all

    # Delete the failure events
    Event.where("action LIKE '%_failed'").delete_all

    # Run the job
    ProofAttachmentMetricsJob.perform_now

    # Should not create notifications since success rate is 100%
    assert_equal 0, Notification.count, 'Should not have created notifications'
  end

  test "doesn't create notifications when failure count is below threshold" do
    # Clear all events and notifications for a clean slate
    Event.delete_all
    Notification.delete_all

    # Create exactly 4 recent failure events (below threshold of 5)
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

    # Create some successful events to establish a baseline
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

    # Run the job - should not create notifications since failures (4) < threshold (5)
    ProofAttachmentMetricsJob.perform_now

    # Should not create notifications since we have fewer than 5 failures
    assert_equal 0, Notification.count, 'Should not create notifications when failures below threshold'
  end

  test 'creates notifications when failure count meets threshold with poor success rate' do
    # Clear all events and notifications for a clean slate
    Event.delete_all
    Notification.delete_all

    # Create exactly 5 recent failure events (at threshold)
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

    # Create fewer successful events to ensure success rate < 95%
    # 5 failures + 1 success = 16.7% success rate (well below 95%)
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

    # Run the job - should create notifications since failures (5) >= threshold (5) AND success rate < 95%
    ProofAttachmentMetricsJob.perform_now

    # Should create notifications for all administrators
    expected_notifications = User.where(type: 'Users::Administrator').count
    assert_equal expected_notifications, Notification.count, 'Should create notifications when both conditions met'

    # Verify notification content
    Notification.find_each do |notification|
      assert_equal 'attachment_failure_warning', notification.action
      assert notification.metadata['success_rate'] < 95.0
      assert_equal 5, notification.metadata['failed']
      assert_equal 6, notification.metadata['total']
    end
  end

  test 'handles empty audit data' do
    # Delete all events
    Event.delete_all

    # Run the job - should not raise any errors
    assert_nothing_raised do
      ProofAttachmentMetricsJob.perform_now
    end

    # Should not create notifications
    assert_equal 0, Notification.count
  end
end
