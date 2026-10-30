# frozen_string_literal: true

require 'test_helper'

module TrainingSessions
  class ScheduleAdditionalServiceTest < ActiveSupport::TestCase
    setup do
      Policy.stubs(:max_training_sessions).returns(3)
      @trainer = create(:trainer)
      @application = create(:application, :approved, :with_all_proofs, application_date: Date.current, assigned_trainer: @trainer)
      @source = create(:training_session, :completed, application: @application, trainer: @trainer)
    end

    test 'the current trainer can create one appointment from the latest completed report' do
      result = nil
      assert_difference ['TrainingSession.count', "Event.where(action: 'training_scheduled').count"], 1 do
        result = ScheduleAdditionalService.new(@source, @trainer, scheduled_for: 2.days.from_now,
                                                                  location: 'Library', internal_notes: 'Private preparation').call
        assert result.success?, result.message
      end
      session = result.data[:training_session]
      assert_equal @trainer, session.trainer
      assert_equal 'Private preparation', session.internal_notes
      assert_equal 'Library', session.location
      assert_equal 'scheduled', session.status
      event = Event.find_by!(action: 'training_scheduled', auditable: session)
      assert_equal @source.id, event.metadata['source_training_session_id']
      assert_not_includes event.metadata.to_json, 'Private preparation'

      assert_no_difference ['TrainingSession.count', 'Event.count'] do
        retry_result = ScheduleAdditionalService.new(@source, @trainer, scheduled_for: 3.days.from_now).call
        assert_not retry_result.success?
      end
    end

    test 'an open appointment cannot be used as an additional-session source' do
      @source = create(:training_session, :scheduled, application: @application, trainer: @trainer)
      assert_no_difference ['TrainingSession.count', 'Event.count'] do
        result = ScheduleAdditionalService.new(@source, @trainer, scheduled_for: 2.days.from_now).call
        assert_not result.success?
      end
    end

    test 'removal between appointments revokes old completed report creation authority' do
      assert_predicate Applications::TrainerAssignment.unassign(@application, actor: create(:admin)), :success?
      assert_nil @application.reload.assigned_trainer_id
      assert @source.reload.status_completed?

      assert_no_difference ['TrainingSession.count', 'Event.count'] do
        result = ScheduleAdditionalService.new(@source, @trainer, scheduled_for: 2.days.from_now).call
        assert_not result.success?
      end
    end

    test 'an older completed report cannot create work after a newer outcome' do
      create(:training_session, :cancelled, application: @application, trainer: @trainer)
      assert_no_difference ['TrainingSession.count', 'Event.count'] do
        result = ScheduleAdditionalService.new(@source, @trainer, scheduled_for: 2.days.from_now).call
        assert_not result.success?
      end
    end

    test 'quota and service window are rechecked for new appointments' do
      Policy.stubs(:max_training_sessions).returns(1)
      result = ScheduleAdditionalService.new(@source, @trainer, scheduled_for: 2.days.from_now).call
      assert_not result.success?
      assert_includes result.message, 'quota'

      Policy.stubs(:max_training_sessions).returns(3)
      @application.update!(application_date: 5.years.ago.to_date)
      result = ScheduleAdditionalService.new(@source, @trainer, scheduled_for: 2.days.from_now).call
      assert_not result.success?
      assert_includes result.message, 'service window'
    end
  end
end
