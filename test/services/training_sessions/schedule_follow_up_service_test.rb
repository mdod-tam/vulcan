# frozen_string_literal: true

require 'test_helper'

module TrainingSessions
  class ScheduleFollowUpServiceTest < ActiveSupport::TestCase
    setup do
      Policy.stubs(:max_training_sessions).returns(3)
      @trainer = create(:trainer)
      @application = create(:application, :approved, :with_all_proofs, application_date: Date.current, assigned_trainer: @trainer)
      @source = create(:training_session, :cancelled, application: @application, trainer: @trainer)
    end

    test 'follow-up uses the canonical latest unresolved-outcome reader and preserves history' do
      assert_equal @source.id, @application.latest_training_follow_up_session.id
      result = nil
      assert_difference ['TrainingSession.count', "Event.where(action: 'training_followup_scheduled').count"], 1 do
        result = ScheduleFollowUpService.new(@source, @trainer, scheduled_for: 3.days.from_now,
                                                                reschedule_reason: 'Constituent requested a new appointment').call
        assert result.success?, result.message
      end
      assert @source.reload.status_cancelled?
      assert_equal @trainer.id, result.data[:training_session].trainer_id
      assert_nil @application.latest_training_follow_up_session
    end

    test 'an open appointment prevents follow-up even when quota remains' do
      create(:training_session, :scheduled, application: @application, trainer: @trainer)
      assert_no_difference ['TrainingSession.count', 'Event.count'] do
        result = ScheduleFollowUpService.new(@source, @trainer, scheduled_for: 3.days.from_now, reschedule_reason: 'Makeup').call
        assert_not result.success?
      end
    end

    test 'a completed source belongs to additional appointment policy' do
      source = create(:training_session, :completed, application: @application, trainer: @trainer)
      assert_nil @application.latest_training_follow_up_session
      assert_no_difference ['TrainingSession.count', 'Event.count'] do
        result = ScheduleFollowUpService.new(source, @trainer, scheduled_for: 3.days.from_now, reschedule_reason: 'Makeup').call
        assert_not result.success?
      end
    end

    test 'removed and reassigned trainers cannot create from historical cancellation' do
      admin = create(:admin)
      assert @application.unassign_trainer!(actor: admin)
      assert @application.assign_trainer!(create(:trainer), actor: admin)

      assert_no_difference ['TrainingSession.count', 'Event.count'] do
        result = ScheduleFollowUpService.new(@source, @trainer, scheduled_for: 3.days.from_now, reschedule_reason: 'Makeup').call
        assert_not result.success?
      end
    end
  end
end
