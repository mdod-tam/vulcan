# frozen_string_literal: true

require 'test_helper'

module Evaluations
  class SubmissionServiceTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      @evaluator = create(:evaluator)
      @product = create(:product, name: 'Accessible Tablet')
      @evaluation = create(:evaluation, evaluator: @evaluator, status: :scheduled, evaluation_date: 1.day.from_now)
      load_seeded_email_templates('evaluator_mailer_evaluation_submission_confirmation')
      ActionMailer::Base.deliveries.clear
    end

    test 'submits evaluation, logs evaluation_completed, and delivers the confirmation' do
      assert_difference('Event.where(action: "evaluation_completed").count', 1) do
        perform_enqueued_jobs do
          result = SubmissionService.new(@evaluation, submission_params, actor: @evaluator).call

          assert result.success?
        end
      end

      assert_equal [[@evaluation.constituent.email]], ActionMailer::Base.deliveries.map(&:to)

      @evaluation.reload
      event = Event.order(:created_at).last

      assert_equal 'completed', @evaluation.status
      assert_equal @evaluation.id, event.metadata['evaluation_id']
      assert_equal @evaluation.application_id, event.metadata['application_id']
      assert_equal 1, event.metadata['products_tried_count']
      assert_equal 1, event.metadata['recommended_products_count']
      assert_includes event.metadata['recommended_product_names'], 'Accessible Tablet'
    end

    test 'submits confirmed evaluation' do
      @evaluation.update!(status: :confirmed)

      assert_difference('Event.where(action: "evaluation_completed").count', 1) do
        result = SubmissionService.new(@evaluation, submission_params, actor: @evaluator).call

        assert result.success?
      end

      assert_equal 'completed', @evaluation.reload.status
    end

    test 'email configuration refusal at enqueue keeps the completed evaluation' do
      ensure_system_audit_actor!
      FeatureFlag.find_by!(name: EmailDelivery.category_control('evaluation')).destroy!

      result = SubmissionService.new(@evaluation, submission_params, actor: @evaluator).call
      assert result.success?
      assert_equal :configuration_error, result.data[:notification]
      perform_enqueued_jobs

      assert_equal 'completed', @evaluation.reload.status
      assert Event.exists?(action: EmailDelivery::Outcome::CONFIGURATION_ERROR)
      assert_not Event.exists?(action: EmailDelivery::Outcome::SUPPRESSED)
      assert_empty ActionMailer::Base.deliveries
    end

    test 'does not submit requested evaluation' do
      @evaluation.update!(status: :requested, evaluation_date: nil)

      assert_no_difference('Event.where(action: "evaluation_completed").count') do
        result = SubmissionService.new(@evaluation, submission_params, actor: @evaluator).call

        assert result.failure?
        assert_equal 'Only scheduled or confirmed evaluations can be completed.', result.message
      end

      assert_equal 'requested', @evaluation.reload.status
    end

    test 'does not submit no-show evaluation' do
      @evaluation.update!(status: :no_show)

      assert_no_difference('Event.where(action: "evaluation_completed").count') do
        result = SubmissionService.new(@evaluation, submission_params, actor: @evaluator).call

        assert result.failure?
        assert_equal 'Only scheduled or confirmed evaluations can be completed.', result.message
      end

      assert_equal 'no_show', @evaluation.reload.status
    end

    test 'does not submit already completed evaluation' do
      @evaluation.update!(status: :completed, evaluation_date: Time.current)

      assert_no_difference('Event.where(action: "evaluation_completed").count') do
        result = SubmissionService.new(@evaluation, submission_params, actor: @evaluator).call

        assert result.failure?
        assert_equal 'Only scheduled or confirmed evaluations can be completed.', result.message
      end

      assert_equal 'completed', @evaluation.reload.status
    end

    test 'does not submit cancelled evaluation' do
      @evaluation.update!(status: :cancelled)

      assert_no_difference('Event.where(action: "evaluation_completed").count') do
        result = SubmissionService.new(@evaluation, submission_params, actor: @evaluator).call

        assert result.failure?
      end

      assert_equal 'cancelled', @evaluation.reload.status
    end

    private

    def submission_params
      ActionController::Parameters.new(
        evaluation: {
          notes: 'Completed evaluation',
          location: 'Main Office',
          evaluation_date: Time.current,
          recommended_product_ids: [@product.id],
          products_tried: [{ product_id: @product.id, reaction: 'Positive' }],
          attendees: [{ name: 'Test Constituent', relationship: 'Self' }]
        }
      )
    end
  end
end
