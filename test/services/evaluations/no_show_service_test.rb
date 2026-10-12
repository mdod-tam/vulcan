# frozen_string_literal: true

require 'test_helper'

module Evaluations
  class NoShowServiceTest < ActiveSupport::TestCase
    setup do
      @evaluator = create(:evaluator)
      @evaluation = create(:evaluation, evaluator: @evaluator, status: :scheduled, evaluation_date: 1.day.from_now)
      @evaluation.update!(evaluation_date: 1.day.ago)
    end

    test 'marks scheduled evaluation as no-show and logs evaluation_no_show' do
      assert_difference('Event.where(action: "evaluation_no_show").count', 1) do
        result = NoShowService.new(@evaluation, @evaluator, { notes: 'Constituent did not attend' }).call

        assert result.success?
      end

      @evaluation.reload
      event = Event.order(:created_at).last

      assert_equal 'no_show', @evaluation.status
      assert_equal 'Constituent did not attend', @evaluation.notes
      assert_equal @evaluation.id, event.metadata['evaluation_id']
      assert_equal @evaluation.application_id, event.metadata['application_id']
      assert_equal 'Constituent did not attend', event.metadata['no_show_notes']
    end

    test 'does not mark completed evaluation as no-show' do
      @evaluation.update!(status: :completed, appointment_completed_at: Time.current, report_submitted_at: Time.current)

      assert_no_difference('Event.where(action: "evaluation_no_show").count') do
        result = NoShowService.new(@evaluation, @evaluator, { notes: 'Too late' }).call

        assert result.failure?
        assert_equal 'Only scheduled or confirmed evaluations can be marked as no-show.', result.message
      end

      assert_equal 'completed', @evaluation.reload.status
    end

    test 'requires scheduled time to have passed' do
      @evaluation.update!(evaluation_date: 1.day.from_now)

      assert_no_difference('Event.where(action: "evaluation_no_show").count') do
        result = NoShowService.new(@evaluation, @evaluator, { notes: 'Future no-show attempt' }).call

        assert result.failure?
        assert_equal 'Evaluation can only be marked as no-show after its scheduled time.', result.message
      end

      assert_equal 'scheduled', @evaluation.reload.status
    end

    test 'stale no-show cannot overwrite a completed report' do
      stale_evaluation = Evaluation.find(@evaluation.id)
      @evaluation.update!(status: :completed, appointment_completed_at: Time.current, report_submitted_at: Time.current)
      original_notes = @evaluation.notes

      assert_no_difference('Event.where(action: "evaluation_no_show").count') do
        result = NoShowService.new(stale_evaluation, @evaluator, { notes: 'Stale no-show' }).call

        assert result.failure?
      end

      assert_equal 'completed', @evaluation.reload.status
      assert_equal original_notes, @evaluation.notes
    end
  end
end
