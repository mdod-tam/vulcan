# frozen_string_literal: true

require 'test_helper'

module TrainingSessions
  class AuditLogBuilderTest < ActiveSupport::TestCase
    setup do
      @trainer = create(:trainer)
      @training_session = create(:training_session, :scheduled, trainer: @trainer)
    end

    test 'returns empty array for nil training session' do
      assert_empty AuditLogBuilder.new(nil).build
    end

    test 'includes events owned by the training session' do
      event = Event.create!(
        user: @trainer,
        action: 'training_scheduled',
        auditable: @training_session,
        metadata: {}
      )

      assert_includes AuditLogBuilder.new(@training_session).build, event
    end

    test 'includes events that reference the training session in metadata' do
      event = Event.create!(
        user: @trainer,
        action: 'training_completed',
        metadata: { training_session_id: @training_session.id.to_s }
      )

      assert_includes AuditLogBuilder.new(@training_session).build, event
    end

    test 'deduplicates overlapping auditable and metadata matches' do
      event = Event.create!(
        user: @trainer,
        action: 'training_rescheduled',
        auditable: @training_session,
        metadata: { training_session_id: @training_session.id }
      )

      logs = AuditLogBuilder.new(@training_session).build
      event_count = logs.count { |log| log.id == event.id }

      assert_equal 1, event_count
    end

    test 'sorts newest first' do
      older = Event.create!(
        user: @trainer,
        action: 'training_scheduled',
        auditable: @training_session,
        metadata: {},
        created_at: 2.hours.ago
      )
      newer = Event.create!(
        user: @trainer,
        action: 'training_completed',
        auditable: @training_session,
        metadata: {},
        created_at: 1.hour.ago
      )

      logs = AuditLogBuilder.new(@training_session).build

      assert_operator logs.index(newer), :<, logs.index(older)
    end
  end
end
