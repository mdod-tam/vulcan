# frozen_string_literal: true

require 'test_helper'

module Evaluators
  class DashboardsControllerTest < ActionDispatch::IntegrationTest
    def setup
      @evaluator = create(:evaluator, first_name: 'Jordan', last_name: 'Evaluator')
      @other_evaluator = create(:evaluator, first_name: 'Morgan', last_name: 'Evaluator')
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
      assert_select 'a[href=?]', admin_applications_path, text: 'Back to Dashboard', count: 0
    end

    test 'evaluator sees only scoped evaluation and application assignment activity' do
      own_event = create_evaluation_event(@evaluation, 'Own evaluation activity')
      other_event = create_evaluation_event(@other_evaluation, 'Other evaluation activity')
      assignment_event = create_assignment_event(@evaluation.application, @evaluator)
      unrelated_assignment_event = create_assignment_event(@other_evaluation.application, @other_evaluator)

      get evaluators_dashboard_path

      assert_response :success
      assert_includes assigns(:activity_logs), own_event
      assert_includes assigns(:activity_logs), assignment_event
      assert_not_includes assigns(:activity_logs), other_event
      assert_not_includes assigns(:activity_logs), unrelated_assignment_event
      assert_includes @response.body, 'Constituent'
      assert_includes @response.body, @evaluation.constituent.full_name
      assert_not_includes @response.body, @other_evaluation.constituent.full_name
      assert_select '#upcoming-evaluations-section tbody tr', text: /#{Regexp.escape(@constituent.full_name)}/ do
        assert_select 'p', text: "Evaluator: #{@evaluator.full_name}"
      end
      assert_not_includes @response.body, @other_evaluator.full_name
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

    test 'dashboard pairs every displayed evaluation with its preloaded evaluator' do
      sign_in_for_integration_test(@admin)
      requested = create(:evaluation, evaluator: @other_evaluator, status: :requested, evaluation_date: nil)
      followup = create(:evaluation, evaluator: @evaluator, status: :cancelled)
      completed = create(:evaluation, :completed, evaluator: @other_evaluator)
      mine = create(:evaluation, evaluator: @admin, status: :scheduled)

      get evaluators_dashboard_path

      assert_response :success
      {
        'needs-scheduling-section' => [requested],
        'upcoming-evaluations-section' => [@evaluation, @other_evaluation, mine],
        'my-upcoming-evaluations-section' => [mine],
        'followup-evaluations-section' => [followup]
      }.each do |section, evaluations|
        evaluations.each do |evaluation|
          assert_select "##{section} tbody tr", text: /#{Regexp.escape(evaluation.constituent.full_name)}/ do
            assert_select 'p', text: "Evaluator: #{evaluation.evaluator.full_name}"
            assert_select 'a[href=?]', evaluators_evaluation_path(evaluation)
          end
        end
      end
      assert_select '.space-y-4 > div', text: /#{Regexp.escape(completed.constituent.full_name)}/ do
        assert_select 'p', text: "Evaluator: #{completed.evaluator.full_name}"
        assert_select 'a[href=?]', evaluators_evaluation_path(completed)
      end
      %i[requested_evaluations_display upcoming_evaluations my_scheduled_evaluations_display
         followup_evaluations_display recent_evaluations].each do |collection|
        assigns(collection).each { |evaluation| assert_predicate evaluation.association(:evaluator), :loaded? }
      end
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

    def create_assignment_event(application, evaluator)
      Event.create!(
        user: @admin,
        action: 'evaluator_assigned',
        auditable: application,
        metadata: { application_id: application.id, evaluator_id: evaluator.id, evaluator_name: evaluator.full_name }
      )
    end
  end
end
