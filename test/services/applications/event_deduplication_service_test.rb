# frozen_string_literal: true

require 'test_helper'

module Applications
  class EventDeduplicationServiceTest < ActiveSupport::TestCase
    setup do
      # Set up mocks for ActiveStorage attachments to prevent byte_size() errors
      setup_attachment_mocks_for_audit_logs
      @application = create(:application)
      @admin = create(:admin)
    end

    test 'correctly deduplicates events with different priorities' do
      service = EventDeduplicationService.new
      time = Time.current

      # Create unique users to avoid email conflicts
      notification_user = create(:user, email: "notification_#{Time.current.to_f}@example.com")
      event_user = create(:user, email: "event_#{Time.current.to_f}@example.com")

      # Create a Notification (low priority) - same timestamp for deduplication
      notification = create(:notification,
                            notifiable: @application,
                            action: 'medical_certification_requested',
                            actor: notification_user,
                            recipient: @application.user,
                            created_at: time)

      # Create an Event (medium priority) - same timestamp for deduplication
      event = Event.create!(
        user: event_user,
        auditable: @application,
        action: 'medical_certification_requested',
        metadata: {},
        created_at: time
      )

      # Create an ApplicationStatusChange (high priority) - same timestamp for deduplication
      status_change = ApplicationStatusChange.create!(
        application: @application,
        user: @admin,
        from_status: 'submitted',
        to_status: 'requested',
        metadata: { change_type: 'medical_certification' },
        created_at: time
      )

      # Execute
      result = service.deduplicate([notification, event, status_change])

      # Verify: Only the highest priority event should remain
      assert_equal 1, result.size
      assert_equal status_change, result.first
    end

    test 'groups events by time window' do
      service = EventDeduplicationService.new
      # Use a time that's at the start of a minute to ensure events fall in same bucket
      time = Time.current.beginning_of_minute

      # Create unique users to avoid email conflicts
      user1 = create(:user, email: "user1_#{Time.current.to_f}@example.com")
      user2 = create(:user, email: "user2_#{Time.current.to_f}@example.com")
      user3 = create(:user, email: "user3_#{Time.current.to_f}@example.com")

      # Create events directly since no :event factory exists
      event1 = Event.create!(
        user: user1,
        auditable: @application,
        action: 'proof_submitted',
        metadata: { proof_type: 'income' },
        created_at: time
      )

      event2 = Event.create!(
        user: user2,
        auditable: @application,
        action: 'proof_submitted',
        metadata: { proof_type: 'income' },
        created_at: time + 30.seconds # Still within same minute
      )

      # Create a third event outside the window (different minute boundary)
      event3 = Event.create!(
        user: user3,
        auditable: @application,
        action: 'proof_submitted',
        metadata: { proof_type: 'income' },
        created_at: time + 70.seconds # Past 1 minute boundary
      )

      result = service.deduplicate([event1, event2, event3])

      # Verify: The first two events are deduplicated, the third is separate
      assert_equal 2, result.size
      assert_includes result, event3
      assert(result.include?(event1) || result.include?(event2))
    end

    test 'keeps distinct secure request notifications for different recipients in the same minute' do
      service = EventDeduplicationService.new
      time = Time.current.beginning_of_minute
      first_recipient = create(:user, email: "first_secure_request_#{Time.current.to_f}@example.com")
      second_recipient = create(:user, email: "second_secure_request_#{Time.current.to_f}@example.com")

      first_notification = create(
        :notification,
        recipient: first_recipient,
        actor: @admin,
        notifiable: @application,
        action: 'provider_info_requested',
        created_at: time,
        metadata: {
          'application_id' => @application.id,
          'secure_request_form_id' => 201,
          'request_batch_id' => 'shared-batch'
        }
      )
      second_notification = create(
        :notification,
        recipient: second_recipient,
        actor: @admin,
        notifiable: @application,
        action: 'provider_info_requested',
        created_at: time + 20.seconds,
        metadata: {
          'application_id' => @application.id,
          'secure_request_form_id' => 202,
          'request_batch_id' => 'shared-batch'
        }
      )

      result = service.deduplicate([first_notification, second_notification])

      assert_equal 2, result.size
      assert_includes result, first_notification
      assert_includes result, second_notification
    end
  end
end
