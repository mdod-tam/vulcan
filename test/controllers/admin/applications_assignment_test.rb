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

      assert_select 'select[name=trainer_id] option', text: trainer.full_name
      assert_select 'select[name=trainer_id] option', text: admin.full_name
    end

    test 'trainer dropdown excludes inactive admins' do
      inactive_admin = create(:admin, first_name: 'Inactive', last_name: 'Admin', status: :inactive)

      get admin_application_path(@application)

      assert_select 'select[name=trainer_id] option', text: inactive_admin.full_name, count: 0
    end

    test 'evaluator dropdown includes active admins through inherent can_evaluate capability' do
      evaluator = create(:evaluator)
      admin = create(:admin, first_name: 'Evaluation', last_name: 'Admin')

      get admin_application_path(@application)
      assert_select 'select[name=evaluator_id] option', text: evaluator.full_name
      assert_select 'select[name=evaluator_id] option', text: admin.full_name
    end

    test 'evaluator dropdown excludes suspended admins' do
      suspended_admin = create(:admin, first_name: 'Suspended', last_name: 'Admin', status: :suspended)

      get admin_application_path(@application)

      assert_select 'select[name=evaluator_id] option', text: suspended_admin.full_name, count: 0
    end

    test 'evaluator dropdown excludes trainers with explicit can_evaluate capability' do
      trainer = create(:trainer, first_name: 'Cross', last_name: 'Trainer')
      create(:role_capability, user: trainer, capability: 'can_evaluate')

      get admin_application_path(@application)

      assert_select 'select[name=evaluator_id] option', text: trainer.full_name, count: 0
    end

    test 'assigned training detail link exits the application turbo frame' do
      training_session = create(:training_session, :requested, application: @application, trainer: create(:trainer))

      get admin_application_path(@application)

      assert_response :success
      assert_select "a[href='#{trainers_training_session_path(training_session)}'][data-turbo-frame='_top']",
                    text: 'View Details'
      assert_select "form[action='#{unassign_trainer_admin_application_path(@application)}']"
    end

    test 'admin can unassign active trainer' do
      training_session = create(:training_session, :requested, application: @application, trainer: create(:trainer))

      assert_difference -> { Event.where(action: 'trainer_unassigned', auditable: @application).count }, 1 do
        post unassign_trainer_admin_application_path(@application)
      end

      assert_redirected_to admin_application_path(@application)
      assert_equal 'Trainer assignment removed.', flash[:notice]
      training_session.reload
      assert training_session.status_cancelled?
      assert training_session.cancellation_initiator_admin?
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

    test 'trainer assignment form is hidden when completed training quota is exhausted' do
      Policy.find_or_create_by(key: 'max_training_sessions').update!(value: 3)
      trainer = create(:trainer)
      create_list(:training_session, 3, :completed, application: @application, trainer: trainer)

      get admin_application_path(@application)

      assert_response :success
      assert_select 'form[data-testid="trainer-assignment-form"]', count: 0
      assert_select 'strong', text: 'Maximum Reached'
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
