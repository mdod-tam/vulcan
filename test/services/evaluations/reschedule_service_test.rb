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
      @evaluation.update!(status: :completed, appointment_completed_at: Time.current, report_submitted_at: Time.current)

      assert_no_difference('Event.where(action: "evaluation_rescheduled").count') do
        result = RescheduleService.new(
          @evaluation,
          @evaluator,
          { evaluation_date: 3.days.from_now, location: 'Library', reschedule_reason: 'Retry' }
        ).call

        assert result.failure?
        assert_equal 'Only scheduled, confirmed, cancelled, or no-show evaluations can be rescheduled.', result.message
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
      assert_equal 'evaluation_date must be in the future', result.message
    end

    test 'stale reschedule cannot change a completed report appointment date or location' do
      stale_evaluation = Evaluation.find(@evaluation.id)
      @evaluation.update!(status: :completed, appointment_completed_at: Time.current, report_submitted_at: Time.current)
      original_date = @evaluation.evaluation_date
      original_location = @evaluation.location

      assert_no_difference('Event.where(action: "evaluation_rescheduled").count') do
        result = RescheduleService.new(
          stale_evaluation,
          @evaluator,
          { evaluation_date: 3.days.from_now, location: 'Replacement location', reschedule_reason: 'Stale appointment change' }
        ).call

        assert result.failure?
      end

      @evaluation.reload
      assert_equal 'completed', @evaluation.status
      assert_equal original_date, @evaluation.evaluation_date
      assert_equal original_location, @evaluation.location
    end

    test 'reschedule and followup appointments recheck current application approval' do
      @evaluation.application.transition_status!(:archived, actor: create(:admin))
      original_date = @evaluation.evaluation_date

      %i[scheduled cancelled no_show].each do |status|
        @evaluation.update!(status: status)
        assert_no_difference('Event.where(action: "evaluation_rescheduled").count') do
          result = RescheduleService.new(
            @evaluation, @evaluator,
            { evaluation_date: 3.days.from_now, reschedule_reason: 'Arrange another assessment' }
          ).call

          assert result.failure?
          assert_includes result.message, 'Only approved applications'
        end
        assert_equal status.to_s, @evaluation.reload.status
        assert_equal original_date, @evaluation.evaluation_date
      end
    end
  end
end
