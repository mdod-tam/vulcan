# frozen_string_literal: true

require 'test_helper'

module Evaluations
  class ScheduleServiceTest < ActiveSupport::TestCase
    setup do
      @evaluator = create(:evaluator)
      @evaluation = create(:evaluation, evaluator: @evaluator, status: :requested, evaluation_date: nil)
    end

    test 'schedules evaluation and logs evaluation_scheduled' do
      scheduled_time = 2.days.from_now

      assert_difference('Event.where(action: "evaluation_scheduled").count', 1) do
        result = ScheduleService.new(
          @evaluation,
          @evaluator,
          { evaluation_date: scheduled_time, location: 'Library', notes: 'Call on arrival' }
        ).call

        assert result.success?
      end

      @evaluation.reload
      event = Event.order(:created_at).last

      assert_equal 'scheduled', @evaluation.status
      assert_in_delta scheduled_time, @evaluation.evaluation_date, 1.second
      assert_equal 'Library', @evaluation.location
      assert_equal @evaluation.id, event.metadata['evaluation_id']
      assert_equal @evaluation.application_id, event.metadata['application_id']
      assert_equal 'Library', event.metadata['location']
    end
  end
end
