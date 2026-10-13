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
                            user: create(:constituent, speech_disability: true))
    end

    # --- dropdown rendering ---

    test 'admin application show renders dropdown assignment (no per-practitioner buttons)' do
      create(:trainer)
      create(:evaluator)

      get admin_application_path(@application)
      assert_response :success

      assert_select 'form[data-testid="trainer-assignment-form"] select[name=trainer_id]'
      assert_select 'form[data-testid="trainer-assignment-form"] input[type=submit]'

      # No "Assign <Full Name>" one-button-per-practitioner pattern remains.
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

    test 'evaluator dropdown excludes trainers with explicit can_evaluate capability' do
      trainer = create(:trainer, first_name: 'Cross', last_name: 'Trainer')
      create(:role_capability, user: trainer, capability: 'can_evaluate')

      get admin_application_path(@application)

      assert_select "select[name=evaluator_id] option[value='#{trainer.id}']", count: 0
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

    test 'assigned training detail link exits the application turbo frame' do
      training_session = create(:training_session, :requested, application: @application, trainer: create(:trainer))

      get admin_application_path(@application)

      assert_response :success
      assert_select "a[href='#{trainers_training_session_path(training_session)}'][data-turbo-frame='_top']",
                    text: 'View Details'
      assert_select "form[action='#{unassign_trainer_admin_application_path(@application)}']"
      assert_select 'dialog#trainer-unassign-confirm-dialog' do
        assert_select 'p', text: I18n.t('admin.applications.unassign_trainer.confirm', count: 1)
        assert_select 'button', text: I18n.t('admin.applications.unassign_trainer.confirm_no')
        assert_select 'button', text: I18n.t('admin.applications.unassign_trainer.confirm_yes')
      end
    end

    test 'unassign trainer confirmation includes all open training sessions' do
      trainer = create(:trainer)
      create(:training_session, :requested, application: @application, trainer: trainer)
      create(:training_session, :scheduled, application: @application, trainer: trainer)

      get admin_application_path(@application)

      assert_response :success
      assert_select 'dialog#trainer-unassign-confirm-dialog p',
                    text: I18n.t('admin.applications.unassign_trainer.confirm', count: 2)
    end

    test 'admin can unassign active trainer and cancel all open training sessions' do
      trainer = create(:trainer)
      training_session = create(:training_session, :requested, application: @application, trainer: trainer)
      scheduled_session = create(:training_session, :scheduled, application: @application, trainer: trainer)

      assert_difference -> { Event.where(action: 'trainer_unassigned', auditable: @application).count }, 1 do
        post unassign_trainer_admin_application_path(@application)
      end

      assert_redirected_to admin_application_path(@application)
      assert_equal 'Trainer assignment removed.', flash[:notice]
      training_session.reload
      assert training_session.status_cancelled?
      assert training_session.cancellation_initiator_admin?
      scheduled_session.reload
      assert scheduled_session.status_cancelled?
      assert scheduled_session.cancellation_initiator_admin?
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
      create(:role_capability, user: wrong_role, capability: 'can_evaluate')
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
      create(:role_capability, user: wrong_role, capability: 'can_train')
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

    test 'trainer assignment form is hidden when completed training quota is exhausted' do
      Policy.find_or_create_by(key: 'max_training_sessions').update!(value: 3)
      trainer = create(:trainer)
      create_list(:training_session, 3, :completed, application: @application, trainer: trainer)

      get admin_application_path(@application)

      assert_response :success
      assert_select 'form[data-testid="trainer-assignment-form"]', count: 0
      assert_select 'strong', text: 'Maximum Reached'
    end

    test 'trainer assignment form is hidden when reserved training quota is exhausted' do
      Policy.find_or_create_by(key: 'max_training_sessions').update!(value: 3)
      trainer = create(:trainer)
      create_list(:training_session, 2, :completed, application: @application, trainer: trainer)
      create(:training_session, :scheduled, application: @application, trainer: trainer)

      get admin_application_path(@application)

      assert_response :success
      assert_select 'form[data-testid="trainer-assignment-form"]', count: 0
      assert_select 'p', text: %r{3 / 3 sessions reserved, 0 remaining}
      assert_select 'strong', text: 'Maximum Reached'
    end

    test 'admin application show calls out latest cancelled training session that needs follow-up' do
      trainer = create(:trainer)
      cancelled_session = create(:training_session, :cancelled, application: @application, trainer: trainer)

      get admin_application_path(@application)

      assert_response :success
      assert_select '[data-testid="training-follow-up-needed"]' do
        assert_select 'p', text: 'Training needs follow-up'
        assert_select 'a[href=?]', trainers_training_session_path(cancelled_session), text: 'View historical session'
      end
      assert_select 'h3', text: 'Assign trainer for follow-up'
      assert_select 'form[data-testid="trainer-assignment-form"] input[type=submit][value=?]',
                    'Assign trainer for follow-up'
    end

    test 'admin application show hides follow-up callout when newer active training exists' do
      trainer = create(:trainer)
      create(:training_session, :cancelled, application: @application, trainer: trainer, created_at: 2.days.ago)
      create(:training_session, :scheduled, application: @application, trainer: trainer, created_at: 1.day.ago)

      get admin_application_path(@application)

      assert_response :success
      assert_select '[data-testid="training-follow-up-needed"]', count: 0
      assert_select 'h3', text: 'Current Trainer'
    end

    # --- request_evaluation action ---

    test 'admin can mark an approved application as needing evaluation' do
      assert_nil @application.evaluation_requested_at

      assert_difference -> { Event.where(action: 'evaluation_requested', auditable: @application).count }, 1 do
        post request_evaluation_admin_application_path(@application)
      end

      assert_redirected_to admin_application_path(@application)
      @application.reload
      assert_not_nil @application.evaluation_requested_at
      assert @application.evaluation_request_pending?

      event = Event.where(action: 'evaluation_requested', auditable: @application).last
      assert_equal @admin, event.user
      assert_equal @application.id, event.metadata['application_id']
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
  end
end
