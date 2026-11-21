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

      sign_in_for_integration_test(@evaluator, bypass_mfa_enrollment: true)
    end

    def test_should_get_show
      get evaluators_dashboard_path
      assert_response :success
      assert_select 'main', count: 1
      assert_select 'main main', count: 0
      assert_select 'div#main-content[tabindex="-1"][aria-labelledby="evaluator-dashboard-title"]'
      assert_select 'h1#evaluator-dashboard-title', text: 'Evaluations Dashboard', count: 1
      assert_select 'a.skip-link[href="#main-content"]', text: 'Skip to evaluations dashboard', count: 1
      assert_select '.summary-card .summary-card-content', count: 3
      assert_select '.summary-card h3.summary-card-title', count: 3
      assert_select '.summary-card .summary-card-count', count: 3
      assert_select '.summary-card .summary-card-actions', count: 3
      assert_select '.summary-card-actions a.btn-outline', count: 3
      assert_select '.summary-card a.btn-primary', count: 0
      assert_select '#needs-evaluator-card, #needs-evaluator-section, select[name=evaluator_id]', count: 0
      assert_nil assigns(:unassigned_evaluation_requests)
      assert_nil assigns(:assignable_evaluators)
      assert_dashboard_link_names
      assert_select '#upcoming-evaluations-section [role="region"][tabindex="0"][aria-labelledby="upcoming-evaluations-heading"] table[aria-labelledby="upcoming-evaluations-heading"]'
      assert_select 'a[href=?]', admin_dashboard_path, text: 'Back to Dashboard', count: 0
      assert_select 'a[href=?]', admin_applications_path, text: 'Back to Applications', count: 0
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
      assert_equal @evaluation, assigns(:scheduled_summary).oldest.record
      assert_equal 1, assigns(:scheduled_summary).count
    end

    test 'admin sees broader recent evaluation activity' do
      sign_in_for_integration_test(@admin, bypass_mfa_enrollment: true)
      own_event = create_evaluation_event(@evaluation, 'Evaluator activity')
      other_event = create_evaluation_event(@other_evaluation, 'Other evaluator activity')

      get evaluators_dashboard_path

      assert_response :success
      assert_includes assigns(:activity_logs), own_event
      assert_includes assigns(:activity_logs), other_event
      assert_select 'nav[aria-label="Return navigation"]' do
        assert_select 'a[href=?]', admin_dashboard_path, text: 'Back to Dashboard'
        assert_select 'a[href=?]', admin_applications_path, text: 'Back to Applications'
      end
      assert_select '.summary-card.summary-card-compact', count: 4
      assert_select '.summary-card-actions a.btn-outline', count: 5
      assert_equal(['Assign evaluator', 'Schedule evaluation', 'Enter evaluation report', 'Review follow-up'],
                   css_select('.summary-card h3').map { |heading| heading.text.squish })
      assert_select 'a[href=?]', evaluators_evaluations_path(status: 'completed'), text: 'View All'
      assert_dashboard_link_names
    end

    test 'admin can assign eligible evaluators to equipment and explicit requests across fulfillment types' do
      sign_in_for_integration_test(@admin, bypass_mfa_enrollment: true)
      equipment = assignment_application(needs_evaluator_since: 10.days.ago)
      voucher = assignment_application(fulfillment_type: :voucher, evaluation_requested_at: 4.days.ago, needs_evaluator_since: 30.days.ago)
      requested_equipment = assignment_application(equipment_needs_initialized_at: Time.current, evaluation_requested_at: 2.days.ago)
      requeued = assignment_application(evaluation_requested_at: 20.days.ago, needs_evaluator_since: 6.days.ago)
      create(:evaluation, application: requeued, status: :cancelled, created_at: 19.days.ago)
      unrequested = assignment_application(fulfillment_type: :voucher)
      completed = assignment_application(needs_evaluator_since: 20.days.ago)
      create(:evaluation, :completed, application: completed)
      fulfilled = assignment_application(equipment_needs_initialized_at: Time.current)
      @evaluation.application.update!(fulfillment_type: :equipment, application_date: Date.current)
      inactive = create(:evaluator, status: :inactive)
      granted = create(:trainer)
      create(:role_capability, user: granted, capability: 'can_evaluate')
      ungranted = create(:trainer)

      get evaluators_dashboard_path

      assert_response :success
      requests = assigns(:unassigned_evaluation_requests)
      assert_includes requests, equipment
      assert_includes requests, voucher
      assert_includes requests, requested_equipment
      assert_includes requests, requeued
      [unrequested, completed, fulfilled, @evaluation.application, @other_evaluation.application].each do |application|
        assert_not_includes requests, application
      end
      assert_equal equipment, assigns(:oldest_evaluation_request)
      assert_equal voucher.reload.evaluation_requested_at, assigns(:evaluation_request_dates).fetch(voucher.id)
      assert_equal requested_equipment.reload.evaluation_requested_at, assigns(:evaluation_request_dates).fetch(requested_equipment.id)
      assert_equal requeued.reload.needs_evaluator_since, assigns(:evaluation_request_dates).fetch(requeued.id)
      assert_select '#needs-evaluator-card a[href=?]', "#evaluation-request-#{equipment.id}", text: /#{Regexp.escape(equipment.user.full_name)}/
      assert_select '#needs-evaluator-section[tabindex="-1"] [role=region][tabindex="0"] table[aria-labelledby="needs-evaluator-heading"]'
      [equipment, voucher, requested_equipment, requeued].each do |application|
        assert_select "tr#evaluation-request-#{application.id}[tabindex='-1']" do
          assert_select 'form[action=?][method=post]', assign_evaluator_admin_application_path(application) do
            assert_select 'input[type=hidden][name=return_context][value=evaluation_dashboard]'
            assert_select 'label[for=?]', "evaluator_id_#{application.id}", text: "Select evaluator for #{application.user.full_name}"
            assert_select 'select[name=evaluator_id][required]:not([data-action])' do
              [@admin, @evaluator, granted].each do |person|
                assert_select 'option[value=?]', person.id.to_s, text: "#{person.full_name} (#{person.email})"
              end
              [inactive, ungranted].each { |person| assert_select 'option[value=?]', person.id.to_s, count: 0 }
              assert_select 'option[selected]', count: 0
            end
            assert_select 'input[type=submit][value="Assign evaluator"][aria-label=?]', "Assign evaluator for #{application.user.full_name}"
          end
        end
        assert_predicate requests.find { |request| request.id == application.id }.association(:user), :loaded?
      end
      assert_dashboard_link_names
    end

    test 'admin assignment queue retains unknown wait dates and explains expired service windows' do
      sign_in_for_integration_test(@admin, bypass_mfa_enrollment: true)
      unknown = assignment_application(needs_evaluator_since: nil)
      expired = assignment_application(application_date: (Policy.waiting_period_years + 1).years.ago.to_date, needs_evaluator_since: 3.days.ago)

      get evaluators_dashboard_path

      assert_response :success
      assert_select "#evaluation-request-#{unknown.id} td", text: 'Wait date unavailable'
      assert_select "#evaluation-request-#{expired.id}" do
        assert_select 'form', count: 0
        assert_select 'p', text: 'The service window has ended. An evaluator cannot be assigned.'
      end
      assert_select '#needs-evaluator-card', text: /Longest known wait:/
      assert_equal expired, assigns(:oldest_evaluation_request)
    end

    test 'dashboard pairs every displayed evaluation with its preloaded evaluator' do
      sign_in_for_integration_test(@admin, bypass_mfa_enrollment: true)
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
      %w[needs-scheduling-heading upcoming-evaluations-heading my-upcoming-evaluations-table-heading followup-evaluations-heading].each do |heading|
        assert_select "[role='region'][tabindex='0'][aria-labelledby='#{heading}'] table[aria-labelledby='#{heading}']"
      end
      assert_select '#needs-scheduling-section a[aria-label=?]', "View/Schedule evaluation for #{requested.constituent.full_name}"
      assert_select '#upcoming-evaluations-section a[aria-label=?]', "View Details for #{@evaluation.constituent.full_name}"
      assert_select 'a[aria-label=?]', "View completed evaluation for #{completed.constituent.full_name}"
      assert_dashboard_link_names
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

    def assignment_application(fulfillment_type: :equipment, **attributes)
      application = create(:application, :approved, :with_all_proofs, { application_date: Date.current }.merge(attributes))
      application.update!(fulfillment_type:)
      application
    end

    def assert_dashboard_link_names
      css_select('#main-content a[aria-label]').each do |link|
        assert_includes link['aria-label'].squish.downcase, link.text.squish.downcase
      end
    end

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
