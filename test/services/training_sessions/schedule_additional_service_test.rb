# frozen_string_literal: true

require 'test_helper'

module TrainingSessions
  class ScheduleAdditionalServiceTest < ActiveSupport::TestCase
    setup do
      @trainer = create(:trainer)
      @application = create(:application, :approved, user: create(:constituent), application_date: 1.year.ago)
      @source_session = create(:training_session, :scheduled, trainer: @trainer, application: @application)
      update_max_training_sessions(3)
    end

    test 'schedules another session and logs audit event' do
      scheduled_time = 2.weeks.from_now

      assert_difference('TrainingSession.count', 1) do
        assert_difference('Event.where(action: "training_scheduled").count', 1) do
          result = ScheduleAdditionalService.new(
            @source_session,
            @trainer,
            scheduled_for: scheduled_time,
            location: 'Library',
            notes: 'Second session'
          ).call

          assert result.success?
          @additional_session = result.data[:training_session]
        end
      end

      assert_equal 'scheduled', @additional_session.status
      assert_equal @application, @additional_session.application
      assert_equal @trainer, @additional_session.trainer
      assert_in_delta scheduled_time, @additional_session.scheduled_for, 1.second
      assert_equal 'Library', @additional_session.location
      assert_equal 'Second session', @additional_session.notes

      event = Event.where(action: 'training_scheduled').last
      assert_equal @additional_session.id, event.metadata['training_session_id']
      assert_equal @application.id, event.metadata['application_id']
      assert_equal @source_session.id, event.metadata['source_training_session_id']
      assert_equal 'additional', event.metadata['scheduled_via']
    end

    test 'fails when training slots are exhausted' do
      update_max_training_sessions(1)

      assert_no_difference('TrainingSession.count') do
        assert_no_difference('Event.count') do
          result = ScheduleAdditionalService.new(@source_session, @trainer, scheduled_for: 2.weeks.from_now).call

          assert_not result.success?
          assert_equal I18n.t('training_sessions.schedule_additional.quota_exhausted'), result.message
        end
      end
    end

    test 'fails when scheduled time is in the past' do
      assert_no_difference('TrainingSession.count') do
        assert_no_difference('Event.count') do
          result = ScheduleAdditionalService.new(@source_session, @trainer, scheduled_for: 1.day.ago).call

          assert_not result.success?
          assert_equal I18n.t('training_sessions.schedule_additional.scheduled_for_in_future'), result.message
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
