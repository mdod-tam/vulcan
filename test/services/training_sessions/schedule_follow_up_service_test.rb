# frozen_string_literal: true

require 'test_helper'

module TrainingSessions
  class ScheduleFollowUpServiceTest < ActiveSupport::TestCase
    setup do
      @trainer = create(:trainer)
      @application = create(:application, :approved, user: create(:constituent), application_date: 1.year.ago)
      @source_session = create(:training_session, :cancelled, trainer: @trainer, application: @application)
      update_max_training_sessions(3)
    end

    test 'allows follow-up when another active session exists and quota remains' do
      create(:training_session, :scheduled, application: @application, trainer: @trainer)
      scheduled_time = 3.days.from_now

      assert_difference('TrainingSession.count', 1) do
        assert_difference('Event.where(action: "training_followup_scheduled").count', 1) do
          result = ScheduleFollowUpService.new(
            @source_session,
            @trainer,
            scheduled_for: scheduled_time,
            reschedule_reason: 'Makeup training',
            location: 'Library'
          ).call

          assert result.success?
          @follow_up_session = result.data[:training_session]
        end
      end

      assert_equal 'scheduled', @follow_up_session.status
      assert_equal @application, @follow_up_session.application
      assert_equal @trainer, @follow_up_session.trainer
      assert_in_delta scheduled_time, @follow_up_session.scheduled_for, 1.second
      assert_equal 'Makeup training', @follow_up_session.reschedule_reason

      event = Event.where(action: 'training_followup_scheduled').last
      assert_equal @follow_up_session.id, event.metadata['training_session_id']
      assert_equal @source_session.id, event.metadata['previous_training_session_id']
    end

    test 'fails when reserved training slots are exhausted' do
      update_max_training_sessions(2)
      create(:training_session, :completed, application: @application, trainer: @trainer)
      create(:training_session, :scheduled, application: @application, trainer: @trainer)

      assert_no_difference('TrainingSession.count') do
        assert_no_difference('Event.count') do
          result = ScheduleFollowUpService.new(
            @source_session,
            @trainer,
            scheduled_for: 3.days.from_now,
            reschedule_reason: 'Try after quota'
          ).call

          assert_not result.success?
          assert_equal I18n.t('training_sessions.schedule_follow_up.quota_exhausted'), result.message
        end
      end
    end

    private

    def update_max_training_sessions(value)
      policy = Policy.find_or_create_by(key: 'max_training_sessions')
      policy.updated_by = create(:admin)
      policy.update!(value: value)
    end
  end
end
