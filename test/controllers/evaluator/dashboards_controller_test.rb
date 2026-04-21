# frozen_string_literal: true

require 'test_helper'

module Evaluators
  class DashboardsControllerTest < ActionDispatch::IntegrationTest
    def setup
      @evaluator = create(:evaluator) # Using factory
      @other_evaluator = create(:evaluator)
      @admin = create(:admin)
      @constituent = create(:constituent, first_name: 'Scoped', last_name: 'Constituent')
      @other_constituent = create(:constituent, first_name: 'Unrelated', last_name: 'Constituent')
      @evaluation = create(:evaluation, evaluator: @evaluator, constituent: @constituent, status: :scheduled)
      @other_evaluation = create(:evaluation, evaluator: @other_evaluator, constituent: @other_constituent, status: :scheduled)

      # Use the correct sign-in helper for integration tests
      sign_in_for_integration_test(@evaluator)
    end

    def test_should_get_show
      get evaluators_dashboard_path
      assert_response :success
    end

    test 'evaluator sees only scoped evaluation and application fulfillment activity' do
      own_event = create_evaluation_event(@evaluation, 'Own evaluation activity')
      other_event = create_evaluation_event(@other_evaluation, 'Other evaluation activity')
      fulfillment_event = create_application_event(@evaluation.application, 'Scoped fulfillment activity')
      unrelated_fulfillment_event = create_application_event(@other_evaluation.application, 'Unrelated fulfillment activity')

      get evaluators_dashboard_path

      assert_response :success
      assert_includes assigns(:activity_logs), own_event
      assert_includes assigns(:activity_logs), fulfillment_event
      assert_not_includes assigns(:activity_logs), other_event
      assert_not_includes assigns(:activity_logs), unrelated_fulfillment_event
      assert_includes @response.body, 'Constituent'
      assert_includes @response.body, @evaluation.constituent.full_name
      assert_not_includes @response.body, @other_evaluation.constituent.full_name
    end

    test 'admin sees broader recent evaluation activity' do
      sign_in_for_integration_test(@admin)
      own_event = create_evaluation_event(@evaluation, 'Evaluator activity')
      other_event = create_evaluation_event(@other_evaluation, 'Other evaluator activity')

      get evaluators_dashboard_path

      assert_response :success
      assert_includes assigns(:activity_logs), own_event
      assert_includes assigns(:activity_logs), other_event
    end

    test 'recent activity feed is limited' do
      11.times do |index|
        create_evaluation_event(@evaluation, "Evaluation activity #{index}", created_at: index.minutes.ago)
      end

      get evaluators_dashboard_path

      assert_response :success
      assert_equal 10, assigns(:activity_logs).size
    end

    private

    def create_evaluation_event(evaluation, notes, created_at: Time.current)
      Event.create!(
        user: evaluation.evaluator,
        action: 'evaluation_scheduled',
        auditable: evaluation,
        metadata: {
          evaluation_id: evaluation.id,
          notes: notes,
          evaluation_date: evaluation.evaluation_date&.iso8601
        },
        created_at: created_at
      )
    end

    def create_application_event(application, notes)
      Event.create!(
        user: @admin,
        action: 'equipment_bids_sent',
        auditable: application,
        metadata: { date: Date.current.iso8601, notes: notes }
      )
    end
  end
end
