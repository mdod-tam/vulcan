# frozen_string_literal: true

require 'test_helper'

module Admin
  # Admin application show dropdown assignment, tightened practitioner scopes,
  # and the admin-initiated evaluation-request flow.
  class ApplicationsAssignmentTest < ActionDispatch::IntegrationTest
    include AuthenticationTestHelper

    setup do
      @admin = create(:admin)
      sign_in_for_integration_test(@admin)
      @application = create(:application, :completed, :with_all_proofs,
                            user: create(:constituent, speech_disability: true), application_date: Date.current)
    end

    test 'admin application show renders dropdown assignment (no per-practitioner buttons)' do
      create(:trainer)
      create(:evaluator)

      get admin_application_path(@application)
      assert_response :success

      assert_select 'form[data-testid="trainer-assignment-form"] select[name=trainer_id]'
      assert_select 'form[data-testid="trainer-assignment-form"] input[type=submit]'

      # The page has no "Assign <Full Name>" button per practitioner.
      assert_select 'button', text: /Assign Test Trainer/, count: 0
    end

    test 'trainer dropdown includes active admins through inherent can_train capability' do
      trainer = create(:trainer)
      admin = create(:admin, first_name: 'Training', last_name: 'Admin')

      get admin_application_path(@application)

      assert_select "select[name=trainer_id] option[value='#{trainer.id}']", text: "#{trainer.full_name} (#{trainer.email})"
      assert_select "select[name=trainer_id] option[value='#{admin.id}']", text: "#{admin.full_name} (#{admin.email})"
    end

    test 'trainer dropdown excludes inactive admins' do
      inactive_admin = create(:admin, first_name: 'Inactive', last_name: 'Admin', status: :inactive)

      get admin_application_path(@application)

      assert_select "select[name=trainer_id] option[value='#{inactive_admin.id}']", count: 0
    end

    test 'evaluator dropdown includes active admins through inherent can_evaluate capability' do
      evaluator = create(:evaluator)
      admin = create(:admin, first_name: 'Evaluation', last_name: 'Admin')

      get admin_application_path(@application)
      assert_select "select[name=evaluator_id] option[value='#{evaluator.id}']", text: "#{evaluator.full_name} (#{evaluator.email})"
      assert_select "select[name=evaluator_id] option[value='#{admin.id}']", text: "#{admin.full_name} (#{admin.email})"
    end

    test 'evaluator dropdown excludes suspended admins' do
      suspended_admin = create(:admin, first_name: 'Suspended', last_name: 'Admin', status: :suspended)

      get admin_application_path(@application)

      assert_select "select[name=evaluator_id] option[value='#{suspended_admin.id}']", count: 0
    end

    test 'dropdowns offer staff granted the other discipline and no one else' do
      granted_evaluator = create(:trainer, first_name: 'Cross', last_name: 'Trainer')
      create(:role_capability, user: granted_evaluator, capability: 'can_evaluate')
      granted_trainer = create(:evaluator, first_name: 'Cross', last_name: 'Evaluator')
      create(:role_capability, user: granted_trainer, capability: 'can_train')
      ungranted = create(:trainer, first_name: 'Plain', last_name: 'Trainer')

      get admin_application_path(@application)

      assert_select "select[name=evaluator_id] option[value='#{granted_evaluator.id}']"
      assert_select "select[name=evaluator_id] option[value='#{ungranted.id}']", count: 0
      assert_select "select[name=trainer_id] option[value='#{granted_trainer.id}']"
    end

    test 'assignment dropdowns distinguish practitioners with the same full name by account email' do
      @application.update!(fulfillment_type: :equipment, application_date: Date.current)
      evaluators = create_list(:evaluator, 2, first_name: 'Same', last_name: 'Name')
      trainers = create_list(:trainer, 2, first_name: 'Same', last_name: 'Name')

      get admin_application_path(@application)
      assert_response :success

      { evaluator_id: evaluators, trainer_id: trainers }.each do |field, people|
        assert_select "select[name=#{field}]" do
          people.each do |person|
            assert_select "option[value='#{person.id}']", text: "#{person.full_name} (#{person.email})"
          end
        end
      end
    end

    test 'assignment dropdowns identify a legacy staff account without email by record id' do
      @application.update!(fulfillment_type: :equipment, application_date: Date.current)
      @admin.update_column(:email, nil)

      get admin_application_path(@application)
      assert_response :success

      %w[evaluator_id trainer_id].each do |field|
        assert_select "select[name=#{field}] option[value='#{@admin.id}']", text: "#{@admin.full_name} (ID ##{@admin.id})"
      end
    end

    test 'assigned training details exit the turbo frame and removal uses native Turbo confirmation' do
      trainer = current_coverage
      training_session = create(:training_session, :requested, application: @application, trainer: trainer)

      get admin_application_path(@application)

      assert_response :success
      assert_select "a[href='#{trainers_training_session_path(training_session)}'][data-turbo-frame='_top']", text: 'View Details'
      assert_coverage_removal_form
      assert_select 'dialog#trainer-unassign-confirm-dialog', count: 0
    end

    test 'coverage removal remains available between appointments without claiming another unresolved appointment' do
      trainer = current_coverage
      report = create(:training_session, :completed, application: @application, trainer: trainer)

      get admin_application_path(@application)

      assert_response :success
      assert_select '[data-testid="trainer-assignment-section"] a[href=?]', trainers_training_session_path(report), text: 'View Details'
      assert_coverage_removal_form
      assert_select 'form[data-testid="trainer-assignment-form"]', count: 0
      assert_equal 0, @application.open_training_sessions_count
    end

    test 'admin removal clears coverage and cancels its one open appointment without changing completed history or another application' do
      trainer = current_coverage
      report = create(:training_session, :completed, application: @application, trainer: trainer, internal_notes: 'Retained completed observations')
      training_session = create(:training_session, :requested, application: @application, trainer: trainer, internal_notes: 'Retained preparation')
      other_application = create(:application, :approved, :with_all_proofs, application_date: Date.current, assigned_trainer: trainer)
      unrelated = create(:training_session, :scheduled, application: other_application, trainer: trainer)
      original_report = report.attributes

      assert_difference -> { Event.where(action: 'trainer_unassigned', auditable: @application).count }, 1 do
        assert_difference -> { Event.where(action: 'training_cancelled', auditable: training_session).count }, 1 do
          post unassign_trainer_admin_application_path(@application)
        end
      end

      assert_redirected_to admin_application_path(@application)
      assert_equal 'Trainer assignment removed.', flash[:notice]
      assert_nil @application.reload.assigned_trainer_id
      assert training_session.reload.status_cancelled?
      assert training_session.cancellation_initiator_admin?
      assert_equal 'Retained preparation', training_session.internal_notes
      assert_equal original_report, report.reload.attributes
      assert unrelated.reload.status_scheduled?
      assert_equal trainer.id, other_application.reload.assigned_trainer_id
    end

    test 'trainer assignment post is blocked when completed training quota is exhausted' do
      Policy.find_or_create_by(key: 'waiting_period_years').update!(value: 3)
      Policy.find_or_create_by(key: 'max_training_sessions').update!(value: 3)
      trainer = create(:trainer)
      @application.update!(application_date: 2.years.ago.to_date)
      create_list(:training_session, 3, :completed, application: @application, trainer: trainer)

      assert_no_difference -> { TrainingSession.count } do
        post assign_trainer_admin_application_path(@application), params: { trainer_id: trainer.id }
      end

      assert_redirected_to admin_application_path(@application)
      assert_equal 'This constituent has used all available training sessions.', flash[:alert]
    end

    test 'evaluator assignment rejects missing malformed unavailable and deleted selections without side effects' do
      @application.update!(application_date: Date.current)
      eligible = create(:evaluator)
      inactive = create(:evaluator, status: :inactive)
      wrong_role = create(:trainer)
      deleted = create(:evaluator)
      deleted_id = deleted.id
      deleted.destroy!
      missing_id = User.maximum(:id) + 1

      [nil, '', missing_id, deleted_id, inactive.id, wrong_role.id, "#{eligible.id}invalid", [eligible.id]].each do |selected_id|
        assert_no_difference ['Evaluation.count', 'Notification.count', "Event.where(action: 'evaluator_assigned').count"] do
          assert_no_enqueued_emails do
            post assign_evaluator_admin_application_path(@application), params: { evaluator_id: selected_id }
          end
        end

        assert_redirected_to admin_application_path(@application)
        assert_equal 'Select an active evaluator.', flash[:alert]
      end
    end

    test 'a trainer becoming suspended after selection receives assignment validation feedback' do
      @application.update!(application_date: Date.current)
      trainer = create(:trainer)
      get admin_application_path(@application)
      assert_select "select[name=trainer_id] option[value='#{trainer.id}']"
      trainer.update!(status: :suspended)

      assert_no_difference ['TrainingSession.count', 'Notification.count', "Event.where(action: 'trainer_assigned').count"] do
        assert_no_enqueued_emails do
          post assign_trainer_admin_application_path(@application), params: { trainer_id: trainer.id }
        end
      end

      assert_redirected_to admin_application_path(@application)
      assert_equal 'Select an active trainer.', flash[:alert]
    end

    test 'trainer assignment rejects missing malformed wrong role and deleted selections without side effects' do
      @application.update!(application_date: Date.current)
      eligible = create(:trainer)
      wrong_role = create(:evaluator)
      deleted = create(:trainer)
      deleted_id = deleted.id
      deleted.destroy!
      missing_id = User.maximum(:id) + 1

      [nil, '', missing_id, deleted_id, wrong_role.id, "#{eligible.id}invalid", [eligible.id]].each do |selected_id|
        assert_no_difference ['TrainingSession.count', 'Notification.count', "Event.where(action: 'trainer_assigned').count"] do
          assert_no_enqueued_emails do
            post assign_trainer_admin_application_path(@application), params: { trainer_id: selected_id }
          end
        end

        assert_redirected_to admin_application_path(@application)
        assert_equal 'Select an active trainer.', flash[:alert]
      end
    end

    test 'assignment endpoints retain administrator and legacy null status assignees' do
      @application.update!(application_date: Date.current)
      assignee = create(:admin)
      assignee.update_columns(status: nil)

      post assign_evaluator_admin_application_path(@application), params: { evaluator_id: assignee.id }
      assert_redirected_to admin_application_path(@application)
      assert_equal assignee.id, @application.evaluations.last.evaluator_id
      assert_nil flash[:alert]

      post assign_trainer_admin_application_path(@application), params: { trainer_id: assignee.id }
      assert_redirected_to admin_application_path(@application)
      assert_equal assignee.id, @application.training_sessions.last.trainer_id
      assert_nil flash[:alert]
    end

    test 'missing application retains the application lookup response for assignment actions' do
      missing_id = Application.maximum(:id) + 1

      [assign_evaluator_admin_application_path(missing_id), assign_trainer_admin_application_path(missing_id)].each do |path|
        post path, params: { evaluator_id: '', trainer_id: '' }
        assert_redirected_to admin_applications_path
      end
    end

    test 'an uncovered application at completed quota has no assignment form and explains unavailable new work' do
      Policy.find_or_create_by(key: 'max_training_sessions').update!(value: 3)
      trainer = create(:trainer)
      create_list(:training_session, 3, :completed, application: @application, trainer: trainer)

      get admin_application_path(@application)

      assert_response :success
      assert_select 'form[data-testid="trainer-assignment-form"]', count: 0
      assert_select 'section[aria-labelledby="admin-training-heading"] p', text: /3 completed,\s+0 reserved,\s+0 remaining of 3\./
      assert_select 'p', text: 'New training assignment is unavailable because capacity or the service window has ended.'
    end

    test 'admin can inspect and remove coverage at the final reserved quota slot' do
      Policy.find_or_create_by(key: 'max_training_sessions').update!(value: 3)
      trainer = current_coverage
      create_list(:training_session, 2, :completed, application: @application, trainer: trainer)
      scheduled = create(:training_session, :scheduled, application: @application, trainer: trainer)

      get admin_application_path(@application)

      assert_response :success
      assert_select 'form[data-testid="trainer-assignment-form"]', count: 0
      assert_select 'section[aria-labelledby="admin-training-heading"] p', text: /2 completed,\s+1 reserved,\s+0 remaining of 3\./
      assert_select '[data-testid="trainer-assignment-section"] a[href=?]', trainers_training_session_path(scheduled), text: 'View Details'
      assert_coverage_removal_form

      post unassign_trainer_admin_application_path(@application)

      assert_redirected_to admin_application_path(@application)
      assert_nil @application.reload.assigned_trainer_id
      assert scheduled.reload.status_cancelled?
      assert_equal 2, @application.completed_training_sessions_count
    end

    test 'admin removal between appointments clears coverage even at completed quota and preserves reports' do
      Policy.find_or_create_by(key: 'max_training_sessions').update!(value: 3)
      trainer = current_coverage
      reports = create_list(:training_session, 3, :completed, application: @application, trainer: trainer)
      original_reports = reports.index_with(&:attributes)
      get admin_application_path(@application)
      assert_response :success
      assert_coverage_removal_form

      assert_no_difference "Event.where(action: 'training_cancelled').count" do
        post unassign_trainer_admin_application_path(@application)
      end

      assert_redirected_to admin_application_path(@application)
      assert_nil @application.reload.assigned_trainer_id
      assert_equal 3, @application.completed_training_sessions_count
      original_reports.each { |report, attributes| assert_equal attributes, report.reload.attributes }
    end

    test 'ordinary cancellation retains trainer coverage and administrative oversight of the latest outcome' do
      trainer = current_coverage
      cancelled_session = create(:training_session, :cancelled, application: @application, trainer: trainer)

      get admin_application_path(@application)

      assert_response :success
      assert_select '[data-testid="trainer-assignment-section"] p', text: /Current Trainer: #{Regexp.escape(trainer.full_name)}/
      assert_select '[data-testid="trainer-assignment-section"] a[href=?]', trainers_training_session_path(cancelled_session), text: 'View Details'
      assert_select 'form[data-testid="trainer-assignment-form"]', count: 0
      assert_coverage_removal_form
      assert_equal trainer.id, @application.reload.assigned_trainer_id
    end

    test 'administrative coverage details point at the latest appointment while retaining older cancelled history' do
      trainer = current_coverage
      old_outcome = create(:training_session, :cancelled, application: @application, trainer: trainer, created_at: 2.days.ago)
      current_appointment = create(:training_session, :scheduled, application: @application, trainer: trainer, created_at: 1.day.ago)

      get admin_application_path(@application)

      assert_response :success
      assert_select '[data-testid="trainer-assignment-section"] a[href=?]', trainers_training_session_path(current_appointment), text: 'View Details'
      assert_select '[data-testid="trainer-assignment-section"] a[href=?]', trainers_training_session_path(old_outcome), count: 0
      assert old_outcome.reload.status_cancelled?
    end

    test 'admin can mark an approved application as needing evaluation' do
      assert_nil @application.evaluation_requested_at

      assert_difference -> { Event.where(action: 'evaluation_requested', auditable: @application).count }, 1 do
        post request_evaluation_admin_application_path(@application),
             headers: { 'User-Agent' => 'Request metadata probe' }, env: { 'REMOTE_ADDR' => '203.0.113.7' }
      end

      assert_redirected_to admin_application_path(@application)
      @application.reload
      assert_not_nil @application.evaluation_requested_at
      assert @application.evaluation_request_pending?

      event = Event.where(action: 'evaluation_requested', auditable: @application).last
      assert_equal @admin, event.user
      assert_equal @application.id, event.metadata['application_id']
      assert_equal 'Request metadata probe', event.user_agent
      assert_equal '203.0.113.7', event.ip_address.to_s
    end

    test 'request_evaluation is idempotent while a request is already pending' do
      @application.update_columns(evaluation_requested_at: 1.hour.ago)
      original = @application.evaluation_requested_at

      assert_no_difference -> { Event.where(action: 'evaluation_requested', auditable: @application).count } do
        post request_evaluation_admin_application_path(@application)
      end

      @application.reload
      assert_equal original.to_i, @application.evaluation_requested_at.to_i
    end

    test 'request_evaluation rejects non-approved applications' do
      draft_app = create(:application, user: create(:constituent))
      post request_evaluation_admin_application_path(draft_app)

      assert_redirected_to admin_application_path(draft_app)
      assert_nil draft_app.reload.evaluation_requested_at
    end

    test 'reassignment moves the open training row to the selected trainer and keeps the appointment' do
      trainer = current_coverage
      replacement = create(:trainer)
      no_show = create(:training_session, :no_show, application: @application, trainer: trainer)
      scheduled = create(:training_session, :scheduled, application: @application, trainer: trainer, location: 'Agreed library room')

      assert_difference -> { Event.where(action: 'trainer_reassigned', auditable: @application).count }, 1 do
        post reassign_trainer_admin_application_path(@application),
             params: { trainer_id: replacement.id, expected_version: @application.training_assignment_version }
      end

      assert_redirected_to admin_application_path(@application)
      assert_equal 'Open training reassigned. Appointment details have been preserved.', flash[:notice]
      assert_equal replacement.id, @application.reload.assigned_trainer_id
      assert_equal replacement.id, scheduled.reload.trainer_id
      assert_equal trainer.id, no_show.reload.trainer_id
      assert_equal 'Agreed library room', scheduled.location
    end

    test 'show offers the coverage transfer when the covering trainer lost access and nothing is open' do
      trainer = current_coverage
      create(:training_session, :completed, application: @application, trainer: trainer)
      replacement = create(:trainer)
      trainer.update_columns(status: User.statuses[:suspended])

      get admin_application_path(@application)

      assert_select '[data-testid="trainer-ineligible-notice"]', text: /#{Regexp.escape(trainer.full_name)} can no longer take training assignments.*Transfer the coverage/m
      assert_select "form[action='#{reassign_trainer_admin_application_path(@application)}']" do
        assert_select "select[name=trainer_id] option[value='#{replacement.id}']"
      end

      post reassign_trainer_admin_application_path(@application),
           params: { trainer_id: replacement.id, expected_version: @application.training_assignment_version }

      assert_redirected_to admin_application_path(@application)
      assert_equal replacement.id, @application.reload.assigned_trainer_id
    end

    test 'show offers no transfer between appointments while the covering trainer can still work' do
      trainer = current_coverage
      create(:training_session, :completed, application: @application, trainer: trainer)

      get admin_application_path(@application)

      assert_select '[data-testid="trainer-ineligible-notice"]', count: 0
      assert_select "form[action='#{reassign_trainer_admin_application_path(@application)}']", count: 0
    end

    test 'reassignment with a stale reviewed version or an unavailable trainer changes nothing' do
      trainer = current_coverage
      replacement = create(:trainer)
      session = create(:training_session, :scheduled, application: @application, trainer: trainer)
      stale = @application.training_assignment_version
      create(:training_session, :no_show, application: @application, trainer: trainer)

      [[replacement.id, stale], [create(:evaluator).id, @application.training_assignment_version], ['', @application.training_assignment_version]].each do |id, version|
        assert_no_difference ['Event.count', 'Notification.count'] do
          post reassign_trainer_admin_application_path(@application), params: { trainer_id: id, expected_version: version }
        end
        assert_redirected_to admin_application_path(@application)
        assert flash[:alert].present?
      end

      assert_equal trainer.id, session.reload.trainer_id
      assert_equal trainer.id, @application.reload.assigned_trainer_id
    end

    test 'only administrators can reassign a trainer' do
      trainer = current_coverage
      session = create(:training_session, :scheduled, application: @application, trainer: trainer)
      sign_in_for_integration_test(trainer)

      assert_no_difference -> { Event.where(action: 'trainer_reassigned').count } do
        post reassign_trainer_admin_application_path(@application),
             params: { trainer_id: create(:trainer).id, expected_version: @application.training_assignment_version }
      end

      assert_equal trainer.id, session.reload.trainer_id
      assert_equal trainer.id, @application.reload.assigned_trainer_id
    end

    test 'show offers reassignment of the reviewed open training and flags an ineligible trainer' do
      trainer = current_coverage
      create(:training_session, :scheduled, application: @application, trainer: trainer)
      replacement = create(:trainer)
      trainer.update_columns(status: User.statuses[:suspended])

      get admin_application_path(@application)

      assert_select '[data-testid="trainer-ineligible-notice"]', text: /#{Regexp.escape(trainer.full_name)} can no longer take training assignments/
      assert_select "form[action='#{reassign_trainer_admin_application_path(@application)}']" do
        assert_select "input[name=expected_version][value='#{@application.reload.training_assignment_version}']"
        assert_select "select[name=trainer_id] option[value='#{replacement.id}']"
      end
    end

    test 'show explains that an expired service window blocks the transfer' do
      trainer = current_coverage
      create(:training_session, :scheduled, application: @application, trainer: trainer)
      @application.update_columns(application_date: 4.years.ago.to_date)

      get admin_application_path(@application)

      assert_select '[data-testid="training-reassignment-unavailable"]', text: /service window .* has ended/
      assert_select "form[action='#{reassign_trainer_admin_application_path(@application)}']", count: 0
    end

    test 'show flags an evaluator who can no longer take evaluator assignments' do
      evaluator = create(:evaluator)
      create(:evaluation, application: @application, constituent: @application.user, evaluator: evaluator, status: :scheduled)
      evaluator.update_columns(status: User.statuses[:suspended])

      get admin_application_path(@application)

      assert_select '[data-testid="evaluator-ineligible-notice"]', text: /#{Regexp.escape(evaluator.full_name)} can no longer take evaluator assignments/
    end

    private

    def current_coverage
      trainer = create(:trainer)
      @application.update!(assigned_trainer: trainer)
      trainer
    end

    def assert_coverage_removal_form
      confirmation = 'Remove trainer coverage and cancel any open appointment? Completed reports remain available.'
      assert_select "form[action='#{unassign_trainer_admin_application_path(@application)}'][data-turbo-confirm=?]", confirmation do
        assert_select 'button', text: 'Unassign Trainer'
      end
    end
  end
end
