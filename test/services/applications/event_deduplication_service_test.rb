# frozen_string_literal: true

require 'test_helper'

module Applications
  class EventDeduplicationServiceTest < ActiveSupport::TestCase
    setup do
      @application = create(:application)
      @admin = create(:admin)
    end

    test 'retains distinct immutable decisions in the same minute ordered by decision time and id' do
      reviewed_at = 1.day.ago.beginning_of_minute
      first = create(:proof_review, :rejected, application: @application, admin: @admin,
                                               reviewed_at: reviewed_at, created_at: 3.days.ago)
      second = create(:proof_review, :rejected, application: @application, admin: @admin,
                                                reviewed_at: reviewed_at, created_at: 4.days.ago)

      result = EventDeduplicationService.new.deduplicate([first, second, first])

      assert_equal [second.id, first.id], result.map(&:id)
      assert_equal reviewed_at, EventDeduplicationService.event_time(result.first)
    end

    test 'retains distinct identity cases resolved in the same minute' do
      events = [101, 102].map do |case_id|
        Event.create!(user: @admin, auditable: @application, action: 'duplicate_review_case_resolved',
                      metadata: { duplicate_review_case_id: case_id }, created_at: Time.current.beginning_of_minute)
      end
      assert_equal events.map(&:id).sort, EventDeduplicationService.new.deduplicate(events).map(&:id).sort
    end

    test 'retains evaluator transfer events without operation ids as separate history entries' do
      evaluation = create(:evaluation, application: @application, constituent: @application.user)
      events = Array.new(2) do
        Event.create!(user: @admin, auditable: evaluation, action: 'evaluator_reassigned',
                      metadata: { application_id: @application.id, evaluation_id: evaluation.id },
                      created_at: Time.current.beginning_of_minute)
      end

      assert_equal events.map(&:id).sort, EventDeduplicationService.new.deduplicate(events).map(&:id).sort
    end

    test 'keeps distinct voucher and signing attention operations while collapsing a repeated operation' do
      %w[initial_voucher_issuance_attention document_signing_request_unconfirmed document_signing_follow_up_failed].each do |action|
        events = %w[first-operation second-operation first-operation].map do |operation_id|
          Event.create!(user: @admin, auditable: @application, action: action,
                        metadata: { operation_id: operation_id }, created_at: Time.current.beginning_of_minute)
        end

        result = EventDeduplicationService.new.deduplicate(events)
        assert_equal 2, result.size
        assert_equal %w[first-operation second-operation], result.map { |event| event.metadata['operation_id'] }.sort
      end
    end

    test 'retains separate profile edits when the masks match in the same minute' do
      events = %w[Before After Before].map do |name|
        AuditEventService.log(action: 'profile_updated_by_admin', actor: @admin, auditable: @application.user,
                              metadata: { changes: { first_name: { old: 'Alice', new: name } } },
                              created_at: Time.current.beginning_of_minute)
      end

      assert_equal events.map(&:id).sort, EventDeduplicationService.new.deduplicate(events).map(&:id).sort
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
                            action: 'disability_certification_requested',
                            actor: notification_user,
                            recipient: @application.user,
                            created_at: time)

      # Create an Event (medium priority) - same timestamp for deduplication
      event = Event.create!(
        user: event_user,
        auditable: @application,
        action: 'disability_certification_requested',
        metadata: {},
        created_at: time
      )

      # Create an ApplicationStatusChange (high priority) - same timestamp for deduplication
      status_change = ApplicationStatusChange.create!(
        application: @application,
        user: @admin,
        from_status: 'submitted',
        to_status: 'requested',
        metadata: { change_type: 'disability_certification' },
        created_at: time
      )

      result = service.deduplicate([notification, event, status_change])

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

      assert_equal 2, result.size
      assert_includes result, event3
      assert(result.include?(event1) || result.include?(event2))
    end

    test 'a certification status change appears once, as its history row' do
      travel_to Time.current.beginning_of_minute + 5.seconds do
        change = @application.transition_disability_certification_status!(:rejected, actor: @admin)

        logs = AuditLogBuilder.new(@application).build_deduplicated_audit_logs

        assert_includes logs, change
        assert_empty(logs.select { |log| log.is_a?(Event) && log.action == 'disability_certification_status_changed' })
      end
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
