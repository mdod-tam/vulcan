# frozen_string_literal: true

require 'test_helper'

module Evaluations
  class CancelServiceTest < ActiveSupport::TestCase
    setup do
      @evaluator = create(:evaluator)
      @evaluation = create(:evaluation, evaluator: @evaluator, status: :scheduled, evaluation_date: 1.day.from_now)
      @evaluation.update!(evaluation_date: 1.day.ago)
    end

    test 'cancels scheduled evaluation after scheduled time and logs evaluation_cancelled' do
      assert_difference('Event.where(action: "evaluation_cancelled").count', 1) do
        result = CancelService.new(@evaluation, @evaluator, { notes: 'Constituent no longer wants evaluation' }).call

        assert result.success?
      end

      assert_equal 'cancelled', @evaluation.reload.status
      assert_equal 'Constituent no longer wants evaluation', @evaluation.notes

      event = Event.order(:created_at).last

      assert_equal @evaluation.id, event.metadata['evaluation_id']
      assert_equal @evaluation.application_id, event.metadata['application_id']
      assert_equal 'Constituent no longer wants evaluation', event.metadata['cancellation_reason']
    end

    test 'cancels requested evaluation' do
      @evaluation.update!(status: :requested, evaluation_date: nil)

      result = CancelService.new(@evaluation, @evaluator, { notes: 'Assigned in error' }).call

      assert result.success?
      assert_equal 'cancelled', @evaluation.reload.status
    end

    test 'cancels confirmed evaluation' do
      @evaluation.update!(status: :confirmed)

      result = CancelService.new(@evaluation, @evaluator, { notes: 'Constituent confirmed cancellation' }).call

      assert result.success?
      assert_equal 'cancelled', @evaluation.reload.status
    end

    test 'does not cancel completed evaluation' do
      @evaluation.update!(status: :completed, evaluation_date: Time.current)

      assert_no_difference('Event.where(action: "evaluation_cancelled").count') do
        result = CancelService.new(@evaluation, @evaluator, { notes: 'Too late' }).call

        assert result.failure?
        assert_equal 'Only requested, scheduled, or confirmed evaluations can be cancelled.', result.message
      end

      assert_equal 'completed', @evaluation.reload.status
    end

    test 'requires cancellation reason' do
      assert_no_difference('Event.where(action: "evaluation_cancelled").count') do
        result = CancelService.new(@evaluation, @evaluator, { notes: '' }).call

        assert result.failure?
        assert_equal 'cancellation reason is required', result.message
      end

      assert_equal 'scheduled', @evaluation.reload.status
    end
  end
end
