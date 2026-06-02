# frozen_string_literal: true

require 'test_helper'

module Evaluations
  class RescheduleServiceTest < ActiveSupport::TestCase
    setup do
      @evaluator = create(:evaluator)
      @evaluation = create(:evaluation, evaluator: @evaluator, status: :scheduled, evaluation_date: 2.days.from_now)
    end

    test 'reschedules evaluation and logs evaluation_rescheduled' do
      old_time = @evaluation.evaluation_date
      new_time = 4.days.from_now

      assert_difference('Event.where(action: "evaluation_rescheduled").count', 1) do
        result = RescheduleService.new(
          @evaluation,
          @evaluator,
          { evaluation_date: new_time, location: 'Home visit', reschedule_reason: 'Constituent requested later date' }
        ).call

        assert result.success?
      end

      @evaluation.reload
      event = Event.order(:created_at).last

      assert_equal 'scheduled', @evaluation.status
      assert_in_delta new_time, @evaluation.evaluation_date, 1.second
      assert_equal 'Home visit', @evaluation.location
      assert_equal old_time.iso8601, event.metadata['old_evaluation_date']
      assert_equal 'Constituent requested later date', event.metadata['reschedule_reason']
    end

    test 'reschedules cancelled evaluation on same record' do
      @evaluation.update!(status: :cancelled)
      new_time = 3.days.from_now

      assert_no_difference('Evaluation.count') do
        result = RescheduleService.new(
          @evaluation,
          @evaluator,
          { evaluation_date: new_time, location: 'Library', reschedule_reason: 'Constituent wants to try again' }
        ).call

        assert result.success?
      end

      assert_equal 'scheduled', @evaluation.reload.status
      assert_in_delta new_time, @evaluation.evaluation_date, 1.second
    end

    test 'reschedules no-show evaluation on same record' do
      @evaluation.update!(status: :no_show)
      new_time = 3.days.from_now

      assert_no_difference('Evaluation.count') do
        result = RescheduleService.new(
          @evaluation,
          @evaluator,
          { evaluation_date: new_time, location: 'Community center', reschedule_reason: 'Constituent wants another appointment' }
        ).call

        assert result.success?
      end

      assert_equal 'scheduled', @evaluation.reload.status
      assert_in_delta new_time, @evaluation.evaluation_date, 1.second
    end

    test 'reschedules legacy rescheduled evaluation on same record' do
      @evaluation.update!(status: :rescheduled)
      new_time = 3.days.from_now

      assert_no_difference('Evaluation.count') do
        result = RescheduleService.new(
          @evaluation,
          @evaluator,
          { evaluation_date: new_time, location: 'Community center', reschedule_reason: 'Legacy rescheduled row needs a date' }
        ).call

        assert result.success?
      end

      assert_equal 'scheduled', @evaluation.reload.status
      assert_in_delta new_time, @evaluation.evaluation_date, 1.second
    end

    test 'does not reschedule completed evaluation' do
      @evaluation.update!(status: :completed, evaluation_date: Time.current)

      assert_no_difference('Event.where(action: "evaluation_rescheduled").count') do
        result = RescheduleService.new(
          @evaluation,
          @evaluator,
          { evaluation_date: 3.days.from_now, location: 'Library', reschedule_reason: 'Retry' }
        ).call

        assert result.failure?
        assert_equal I18n.t('evaluations.reschedule.wrong_status'), result.message
      end

      assert_equal 'completed', @evaluation.reload.status
    end

    test 'requires future rescheduled time' do
      result = RescheduleService.new(
        @evaluation,
        @evaluator,
        { evaluation_date: 1.day.ago, location: 'Library', reschedule_reason: 'Backdate attempt' }
      ).call

      assert result.failure?
      assert_equal I18n.t('evaluations.reschedule.evaluation_date_in_future'), result.message
    end
  end
end
