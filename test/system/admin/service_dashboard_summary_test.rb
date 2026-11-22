# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class ServiceDashboardSummaryTest < ApplicationSystemTestCase
    setup do
      @now = Time.current.change(usec: 0)
      travel_to(@now - 20.days) do
        @admin = create(:admin)
        @trainer = create(:trainer)
        @evaluator = create(:evaluator)
      end
    end

    test 'admin service cards show recorded oldest waits numeric stage averages and useful destinations at both widths' do
      unassigned = training_request('Lena Ortiz', at: @now - 12.days, groups: ['deafblind'])
      unscheduled = assign_training(training_request('Noah Bennett', at: @now - 10.days), at: @now - 8.days)
      scheduled = assign_training(training_request('Maya Chen', at: @now - 8.days, groups: ['deafblind']), at: @now - 6.days)
      finished = assign_training(training_request('Eli Morgan', at: @now - 10.days), at: @now - 8.days)
      schedule_training(scheduled, at: @now - 4.days, visit: @now + 2.days)
      schedule_training(finished, at: @now - 6.days, visit: @now - 2.days)
      complete_training(finished, at: @now - 1.day, visit: @now - 2.days)

      unassigned_evaluation = evaluation_request('Ruby Morris', at: @now - 11.days)
      pending_evaluation = assign_evaluation(evaluation_request('Iris Walker', at: @now - 9.days), at: @now - 7.days)
      scheduled_evaluation = assign_evaluation(evaluation_request('Owen Patel', at: @now - 8.days), at: @now - 6.days)
      finished_evaluation = assign_evaluation(evaluation_request('Ada Rivera', at: @now - 10.days), at: @now - 8.days)
      schedule_evaluation(scheduled_evaluation, at: @now - 4.days, visit: @now + 3.days)
      schedule_evaluation(finished_evaluation, at: @now - 6.days, visit: @now - 3.days)
      complete_evaluation(finished_evaluation, at: @now - 1.day, visit: @now - 3.days)

      system_test_sign_in(@admin, bypass_mfa_enrollment: true)
      visit trainers_dashboard_path
      assert_selector '.summary-card-compact', count: 4
      within('#needs-trainer-card') do
        assert_link 'Lena Ortiz — DeafBlind', href: "#training-request-#{unassigned.id}"
        assert_text 'Waiting since request: 12 days'
        assert_text 'Average request to trainer assignment: 2 days'
      end
      scheduling_card = find_by_id('card-needs-scheduling').find(:xpath, 'ancestor::li')
      within(scheduling_card) do
        assert_link 'Noah Bennett — Deaf', href: trainers_training_session_path(unscheduled)
        assert_text 'Waiting since assignment: 8 days'
        assert_text 'Average assignment to scheduling: 2 days'
        assert_text "Trainer: #{@trainer.full_name}"
      end
      within(find_by_id('card-scheduled').find(:xpath, 'ancestor::li')) do
        assert_link 'Maya Chen — DeafBlind', href: trainers_training_session_path(scheduled)
        assert_text 'Waiting since scheduling: 4 days'
        assert_text 'Average scheduling to completed visit: 4 days'
        assert_text "Trainer: #{@trainer.full_name}"
      end
      within('#needs-scheduling-section tr', text: 'Noah Bennett') { assert_text @trainer.full_name }
      within('#upcoming-sessions-section tr', text: 'Maya Chen') { assert_text @trainer.full_name }
      within('section[aria-labelledby="recent-completed-heading"] li', text: 'Eli Morgan') do
        assert_text "Trainer: #{@trainer.full_name}"
      end
      capture_dashboard('admin-training-service-summary-desktop', width: 1200)
      capture_dashboard('admin-training-service-summary-narrow', width: 390)
      within('#needs-trainer-card') { click_link 'Lena Ortiz — DeafBlind' }
      assert_current_path(trainers_dashboard_path) { |uri| uri.fragment == "training-request-#{unassigned.id}" }
      within("#training-request-#{unassigned.id}") do
        click_button 'Assign trainer'
        assert_selector 'select[name=trainer_id]:invalid'
      end
      assert_nil unassigned.reload.assigned_trainer_id
      capture_dashboard('admin-training-inline-assignment-required-narrow', width: 390)
      within("#training-request-#{unassigned.id}") do
        find("option[value='#{@trainer.id}']").select_option
        click_button 'Assign trainer'
      end
      assert_current_path trainers_dashboard_path
      assert_text 'Trainer successfully assigned.'
      assert_no_selector "#training-request-#{unassigned.id}"
      within('#needs-scheduling-section tr', text: unassigned.user.full_name) do
        assert_text @trainer.full_name
      end
      assert_equal @trainer.id, unassigned.reload.assigned_trainer_id
      assert Event.exists?(auditable: unassigned, user: @admin, action: 'trainer_assigned')
      capture_dashboard('admin-training-inline-assignment-result-desktop', width: 1200)
      visit trainers_dashboard_path
      within(find_by_id('card-needs-scheduling').find(:xpath, 'ancestor::li')) { click_link 'Noah Bennett — Deaf' }
      assert_current_path trainers_training_session_path(unscheduled)
      assert_text 'Noah Bennett'

      visit evaluators_dashboard_path
      assert_selector '.summary-card-compact', count: 4
      within('#needs-evaluator-card') do
        assert_link 'Ruby Morris — Deaf', href: "#evaluation-request-#{unassigned_evaluation.id}"
        assert_text 'Longest known wait: 11 days'
      end
      within("#evaluation-request-#{unassigned_evaluation.id}") do
        assert_selector "select[name=evaluator_id] option[value='#{@evaluator.id}']"
        assert_button 'Assign evaluator'
      end
      within('.summary-card', text: 'Schedule evaluation') do
        assert_link 'Iris Walker — Deaf', href: evaluators_evaluation_path(pending_evaluation)
        assert_text 'Waiting since assignment: 7 days'
        assert_text 'Average assignment to scheduling: 2 days'
        assert_text "Evaluator: #{@evaluator.full_name}"
      end
      within('.summary-card', text: 'Enter evaluation report') do
        assert_link 'Owen Patel — Deaf', href: evaluators_evaluation_path(scheduled_evaluation)
        assert_text 'Waiting since scheduling: 4 days'
        assert_text 'Average scheduling to completed visit: 3 days'
        assert_text "Evaluator: #{@evaluator.full_name}"
      end
      capture_dashboard('admin-evaluation-service-summary-desktop', width: 1200)
      capture_dashboard('admin-evaluation-service-summary-narrow', width: 390)
      within("#evaluation-request-#{unassigned_evaluation.id}") do
        find("option[value='#{@evaluator.id}']").select_option
        click_button 'Assign evaluator'
      end
      assert_current_path evaluators_dashboard_path
      assert_text 'Evaluator successfully assigned.'
      assert_no_selector "#evaluation-request-#{unassigned_evaluation.id}"
      assert_equal @evaluator.id, unassigned_evaluation.evaluations.sole.evaluator_id
      assert Event.exists?(auditable: unassigned_evaluation, user: @admin, action: 'evaluator_assigned')
      capture_dashboard('admin-evaluation-inline-assignment-result-desktop', width: 1200)
      within('.summary-card', text: 'Schedule evaluation') { click_link 'Iris Walker — Deaf' }
      assert_current_path evaluators_evaluation_path(pending_evaluation)
      assert_text 'Iris Walker'

      visit admin_applications_path(view: 'pipeline')
      within('.summary-card', text: 'Enter evaluation report') do
        assert_link 'Iris Walker', href: evaluators_evaluation_path(pending_evaluation)
        assert_text "Evaluator: #{@evaluator.full_name}"
        assert_text 'Longest wait: 7 days'
      end
      capture_dashboard('pipeline-evaluator-report-action-desktop', width: 1200)
      capture_dashboard('pipeline-evaluator-report-action-narrow', width: 390)
    ensure
      page.current_window.resize_to(1200, 800)
    end

    private

    def approved_application(name, groups: ['deaf'])
      first, last = name.split(' ', 2)
      user = create(:constituent, first_name: first, last_name: last, hearing_disability: true, vision_disability: groups.include?('deafblind'))
      create(:application, :approved, :with_all_proofs, user:, application_date: Date.current, program_disability_groups: groups)
    end

    def training_request(name, at:, groups: ['deaf'])
      application = nil
      travel_to(at) do
        application = approved_application(name, groups:)
        result = Applications::TrainingRequestService.new(application:, current_user: application.user).call
        assert result.success?, result.message
      end
      application
    end

    def evaluation_request(name, at:)
      application = nil
      travel_to(at) do
        application = approved_application(name)
        application.request_evaluation!(actor: application.user)
      end
      application
    end

    def assign_training(application, at:)
      travel_to(at) do
        result = Applications::TrainerAssignment.assign(application, @trainer, actor: @admin)
        assert result.success?, result.message
      end
      application.training_sessions.sole
    end

    def assign_evaluation(application, at:)
      travel_to(at) do
        result = Applications::EvaluatorAssignment.assign(application, @evaluator, actor: @admin)
        assert result.success?, result.message
      end
      application.evaluations.sole
    end

    def schedule_training(session, at:, visit:)
      travel_to(at) do
        result = TrainingSessions::ScheduleService.new(session, @trainer, scheduled_for: visit, location: 'Office').call
        assert result.success?, result.message
      end
    end

    def complete_training(session, at:, visit:)
      travel_to(at) do
        result = TrainingSessions::CompleteService.new(session, @trainer, completed_at: visit, constituent_summary: 'Practised device controls.',
                                                                          summary_locale: 'en', duration_hours: '1', product_trained_on_id: create(:product).id).call
        assert result.success?, result.message
      end
    end

    def schedule_evaluation(evaluation, at:, visit:)
      travel_to(at) do
        result = Evaluations::ScheduleService.new(evaluation, @evaluator, evaluation_date: visit, location: 'Office').call
        assert result.success?, result.message
      end
    end

    def complete_evaluation(evaluation, at:, visit:)
      travel_to(at) do
        params = ActionController::Parameters.new(evaluation: { appointment_completed_at: visit, notes: 'Completed assessment.',
                                                                no_suitable_product: '1', recommendation_notes: 'No suitable catalog product.' })
        result = Evaluations::SubmissionService.new(evaluation, params, actor: @evaluator).call
        assert result.success?, result.message
      end
    end

    def capture_dashboard(name, width:)
      page.current_window.resize_to(width, 844)
      page.execute_script('window.scrollTo(0, 0)')
      assert_equal 0, page.evaluate_script('window.scrollY')
      assert_operator page.evaluate_script('document.documentElement.scrollWidth'), :<=, width
      take_screenshot(name, full: true, html: true)
    end
  end
end
