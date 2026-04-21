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
  end
end
