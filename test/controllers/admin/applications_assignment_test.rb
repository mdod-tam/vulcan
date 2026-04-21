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

    test 'trainer dropdown excludes admins without can_train capability' do
      trainer = create(:trainer)
      _plain_admin = create(:admin)

      get admin_application_path(@application)

      assert_select 'select[name=trainer_id] option', text: trainer.full_name
      assert_select 'select[name=trainer_id] option', text: 'Admin User', count: 0
    end

    test 'trainer dropdown includes admins with can_train capability' do
      capable_admin = create(:admin, first_name: 'Trainable', last_name: 'Admin')
      create(:role_capability, user: capable_admin, capability: 'can_train')

      get admin_application_path(@application)
      assert_includes @response.body, capable_admin.full_name
    end

    test 'evaluator dropdown includes admins with can_evaluate capability' do
      evaluator = create(:evaluator)
      capable_admin = create(:admin, first_name: 'Adminy', last_name: 'Evaluator')
      create(:role_capability, user: capable_admin, capability: 'can_evaluate')

      get admin_application_path(@application)
      assert_select 'select[name=evaluator_id] option', text: evaluator.full_name
      assert_select 'select[name=evaluator_id] option', text: capable_admin.full_name
    end

    test 'evaluator dropdown excludes admins without can_evaluate capability' do
      evaluator = create(:evaluator)
      plain_admin = create(:admin, first_name: 'Plain', last_name: 'Admin')

      get admin_application_path(@application)

      assert_select 'select[name=evaluator_id] option', text: evaluator.full_name
      assert_select 'select[name=evaluator_id] option', text: plain_admin.full_name, count: 0
    end

    test 'assigned training detail link exits the application turbo frame' do
      training_session = create(:training_session, :requested, application: @application, trainer: create(:trainer))

      get admin_application_path(@application)

      assert_response :success
      assert_select "a[href='#{trainers_training_session_path(training_session)}'][data-turbo-frame='_top']",
                    text: 'View Details'
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
