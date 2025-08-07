# frozen_string_literal: true

require 'test_helper'

module Trainers
  class TrainingSessionsControllerTest < ActionDispatch::IntegrationTest
  # include AuthenticationTestHelper # Already included via test_helper.rb

    setup do
      # Create a constituent for the application
      constituent = create(:constituent)
      @application = create(:application, :old_enough_for_new_application, user: constituent) # Keep application for association
      @trainer = create(:trainer)
      @admin = create(:admin)

      # Commented out session creations for diagnostic purposes
      @training_session = create(:training_session, :scheduled, trainer: @trainer, application: @application)
      @requested_session = create(:training_session, :requested, trainer: @trainer, application: @application)
      @cancelled_session = create(:training_session, :cancelled, trainer: @trainer, application: @application)
      @no_show_session = create(:training_session, :no_show, trainer: @trainer, application: @application)
      @completed_session = create(:training_session, :completed, trainer: @trainer, application: @application)
      @product = create(:product) # Keep product as it might be needed

      # Setup for other_trainer_session test (Keep for now, might need adjustment later)
      @other_trainer = create(:trainer)
      @other_application = create(:application, :old_enough_for_new_application, user: create(:constituent))
      @other_trainer_session = create(:training_session, :scheduled, trainer: @other_trainer, application: @other_application)

      # Setup for constituent_cancelled_sessions_count test (Keep for now, might need adjustment later)
      @constituent = @application.user
      @app2 = create(:application, :old_enough_for_new_application, user: @constituent) # Another app for the same constituent
      @session1_cancelled = create(:training_session, :cancelled, application: @application, trainer: @trainer)
      @session2_no_show = create(:training_session, :no_show, application: @app2, trainer: @trainer)
    end

  # --- Authorization Tests ---
    test 'trainer should only see their own training sessions' do
      sign_in_for_controller_test @trainer
      # other_trainer_session is created in setup

      get trainers_training_session_url(@training_session) # Trainer's own session
      assert_response :success

      get trainers_training_session_url(@other_trainer_session) # Other trainer's session
      assert_redirected_to trainers_dashboard_path
      assert_equal "You don't have access to this training session.", flash[:alert]
    end

    test 'admin should see any training session' do
      sign_in_for_controller_test @admin
      # other_trainer_session is created in setup

      get trainers_training_session_url(@training_session) # Trainer's session
      assert_response :success

      get trainers_training_session_url(@other_trainer_session) # Other trainer's session
      assert_response :success
    end

    test 'unauthenticated user should be redirected to login' do
      get trainers_training_session_url(@training_session)
      assert_redirected_to sign_in_url
    end

  # --- Show Action Tests ---
    test 'should get show and assign instance variables for trainer' do
      sign_in_for_controller_test @trainer
      # Create the session *inside* the test
      training_session = create(:training_session, :scheduled, trainer: @trainer, application: @application)
      get trainers_training_session_url(training_session) # Use the locally created session
      assert_response :success

      assert_equal training_session, assigns(:training_session)
      assert_equal training_session.application, assigns(:application)
      assert_equal training_session.constituent, assigns(:constituent)
      assert_not_nil assigns(:max_training_sessions) # Assuming Policy.get('max_training_sessions') returns something
      assert_equal training_session.application.training_sessions.completed_sessions.count,
                   assigns(:completed_training_sessions_count)
      assert_equal training_session.application.training_sessions.order(:created_at).pluck(:id).index(training_session.id) + 1,
                   assigns(:session_number)
      assert_not_nil assigns(:constituent_cancelled_sessions_count) # Test the complex query
      assert_not_nil assigns(:history_events) # Test history events are loaded
    end

    test 'should get show and assign instance variables for admin' do
      sign_in_for_controller_test @admin
      get trainers_training_session_url(@training_session)
      assert_response :success

      assert_equal @training_session, assigns(:training_session)
      assert_equal @training_session.application, assigns(:application)
      assert_equal @training_session.constituent, assigns(:constituent)
      assert_not_nil assigns(:max_training_sessions)
      assert_equal @training_session.application.training_sessions.completed_sessions.count,
                   assigns(:completed_training_sessions_count)
      assert_equal @training_session.application.training_sessions.order(:created_at).pluck(:id).index(@training_session.id) + 1,
                   assigns(:session_number)
      assert_not_nil assigns(:constituent_cancelled_sessions_count)
      assert_not_nil assigns(:history_events)
    end

    test 'show action should correctly calculate constituent_cancelled_sessions_count' do
      sign_in_for_controller_test @trainer
      # Create some cancelled/no-show events for the constituent across different applications
      # @constituent, @app2, @session1_cancelled, and @session2_no_show are created in setup

      Event.create!(user: @trainer, action: 'training_cancelled',
                    metadata: { training_session_id: @session1_cancelled.id, application_id: @session1_cancelled.application_id,
                                cancellation_reason: 'Cancelled' })
      Event.create!(user: @trainer, action: 'training_no_show',
                    metadata: { training_session_id: @session2_no_show.id, application_id: @session2_no_show.application_id,
                                no_show_notes: 'No show' })

      get trainers_training_session_url(@training_session)
      assert_response :success

      # Expecting 2 cancelled/no-show events across the constituent's applications
      assert_equal 2, assigns(:constituent_cancelled_sessions_count)
    end

  # --- Status Update Action Tests ---

    test 'update_status should update status and log generic event' do
      sign_in_for_controller_test @trainer
      original_status = @training_session.status # Define original_status here
      new_status = :confirmed

      assert_difference('Event.count') do
        patch update_status_trainers_training_session_url(@training_session),
              params: { training_session: { status: new_status } }
      end

      @training_session.reload
      assert_equal new_status.to_s, @training_session.status
      assert_redirected_to trainers_training_session_url(@training_session)
      assert_equal 'Training session status updated successfully.', flash[:notice][:message]

      event = Event.last
      assert_equal 'training_status_changed', event.action
      assert_equal original_status.to_s, event.metadata['old_status']
      assert_equal new_status.to_s, event.metadata['new_status']
      assert_equal @training_session.id, event.metadata['training_session_id']
      assert_equal @training_session.application_id, event.metadata['application_id']
      assert_equal @trainer, event.user
    end

    test 'update_status should handle no_show status and log specific event' do
      sign_in_for_controller_test @trainer
      # original_status is not used after assignment
      new_status = :no_show
      no_show_notes = 'Constituent did not appear for the session.'

      assert_difference('Event.count') do
        patch update_status_trainers_training_session_url(@training_session),
              params: { training_session: { status: new_status, no_show_notes: no_show_notes } }
      end

      @training_session.reload
      assert_equal new_status.to_s, @training_session.status
      assert_equal no_show_notes, @training_session.no_show_notes
      assert_redirected_to trainers_training_session_url(@training_session)
      assert_equal 'Training session status updated successfully.', flash[:notice][:message]

      event = Event.last
      assert_equal 'training_no_show', event.action
      assert_equal @training_session.id, event.metadata['training_session_id']
      assert_equal @training_session.application_id, event.metadata['application_id']
      assert_equal no_show_notes, event.metadata['no_show_notes']
      assert_equal @trainer, event.user
    end

    test 'update_status should clear cancellation_reason when status changes away from cancelled' do
      sign_in_for_controller_test @trainer
      @cancelled_session.update!(cancellation_reason: 'Was cancelled')
      assert_not_nil @cancelled_session.cancellation_reason

      patch update_status_trainers_training_session_url(@cancelled_session),
            params: { training_session: { status: :scheduled, scheduled_for: 1.day.from_now } }

      @cancelled_session.reload
      assert_equal 'scheduled', @cancelled_session.status
      assert_nil @cancelled_session.cancellation_reason
    end

    test 'update_status should clear no_show_notes when status changes away from no_show' do
      sign_in_for_controller_test @trainer
      @no_show_session.update!(no_show_notes: 'Was no show')
      assert_not_nil @no_show_session.no_show_notes

      patch update_status_trainers_training_session_url(@no_show_session),
            params: { training_session: { status: :scheduled, scheduled_for: 1.day.from_now } }

      @no_show_session.reload
      assert_equal 'scheduled', @no_show_session.status
      assert_nil @no_show_session.no_show_notes
    end

  # --- Complete Action Tests ---
    test 'complete should update status to completed, set completed_at, notes, product, and log specific event' do
      sign_in_for_controller_test @trainer
      notes = 'Training session completed successfully.'
      # @product is created in setup

      assert_difference('Event.count') do
        post complete_trainers_training_session_url(@training_session),
             params: { notes: notes, product_trained_on_id: @product.id }
      end

      @training_session.reload
      assert_equal 'completed', @training_session.status
      assert_not_nil @training_session.completed_at
      assert_equal notes, @training_session.notes
      assert_equal @product, @training_session.product_trained_on
      assert_nil @training_session.cancellation_reason # Ensure cleared
      assert_nil @training_session.no_show_notes # Ensure cleared
      assert_redirected_to trainers_training_session_url(@training_session)
      assert_equal 'Training session completed successfully.', flash[:notice][:message]

      event = Event.last
      assert_equal 'training_completed', event.action
      assert_equal @training_session.id, event.metadata['training_session_id']
      assert_equal @training_session.application_id, event.metadata['application_id']
      assert_not_nil event.metadata['completed_at']
      assert_equal notes, event.metadata['notes']
      assert_equal @product.name, event.metadata['product_trained_on']
      assert_equal @trainer, event.user
    end

    test 'complete should fail without notes' do
      sign_in_for_controller_test @trainer
      # @product is created in setup

      assert_no_difference('Event.count') do
        post complete_trainers_training_session_url(@training_session),
             params: { product_trained_on_id: @product.id }
      end

      @training_session.reload
      assert_equal 'scheduled', @training_session.status # Status should not change
      assert_response :unprocessable_content
      assert_includes @response.body, 'Failed to complete training session:' # Check for error message in body
    end

    test 'complete should fail without product_trained_on_id' do
      sign_in_for_controller_test @trainer
      notes = 'Training session completed successfully.'

      assert_no_difference('Event.count') do
        post complete_trainers_training_session_url(@training_session), params: { notes: notes }
      end

      @training_session.reload
      assert_equal 'scheduled', @training_session.status # Status should not change
      assert_response :unprocessable_content
      assert_includes @response.body, 'Failed to complete training session:' # Check for error message in body
    end

  # --- Schedule Action Tests ---
    test 'schedule should update status to scheduled, set scheduled_for, notes, and log specific event' do
      sign_in_for_controller_test @trainer
      scheduled_time = 2.days.from_now
      notes = 'Scheduling notes.'

      # Store the starting count before any operations
      starting_event_count = Event.count

      # Perform the action
      post schedule_trainers_training_session_url(@requested_session),
           params: { scheduled_for: scheduled_time, notes: notes }

      # Check the resulting count directly
      assert_equal starting_event_count + 1, Event.count,
                   'Expected Event.count to increase by 1 but it remained the same'

      # Verify the training session updates
      @requested_session.reload
      assert_equal 'scheduled', @requested_session.status
      assert_in_delta scheduled_time, @requested_session.scheduled_for, 1.second # Use assert_in_delta for time comparisons
      assert_equal notes, @requested_session.notes
      assert_nil @requested_session.cancellation_reason # Ensure cleared
      assert_nil @requested_session.no_show_notes # Ensure cleared
      assert_redirected_to trainers_training_session_url(@requested_session)
      assert_equal 'Training session scheduled successfully.', flash[:notice][:message]

      # Verify the event content
      event = Event.last
      assert_equal 'training_scheduled', event.action
      assert_equal @requested_session.id, event.metadata['training_session_id']
      assert_equal @requested_session.application_id, event.metadata['application_id']
      assert_not_nil event.metadata['scheduled_for'] # Check that scheduled_for is in metadata
      assert_equal notes, event.metadata['notes']
      assert_equal @trainer, event.user
    end

    test 'schedule should fail without scheduled_for' do
      sign_in_for_controller_test @trainer
      notes = 'Scheduling notes.'

      assert_no_difference('Event.count') do
        post schedule_trainers_training_session_url(@requested_session), params: { notes: notes }
      end

      @requested_session.reload
      assert_equal 'requested', @requested_session.status # Status should not change
      assert_response :unprocessable_content
      assert_includes @response.body, 'Failed to schedule training session:' # Check for error message in body
    end

  # --- Reschedule Action Tests ---
    test 'reschedule should update scheduled_for, reschedule_reason, status to scheduled, and log specific event' do
      sign_in_for_controller_test @trainer
      new_scheduled_time = 3.days.from_now
      reschedule_reason = 'Trainer unavailable at original time.'
      # original_scheduled_for is not used after assignment

      assert_difference('Event.count') do
        post reschedule_trainers_training_session_url(@training_session),
             params: { scheduled_for: new_scheduled_time, reschedule_reason: reschedule_reason }
      end

      @training_session.reload
      assert_equal 'scheduled', @training_session.status # Status should be scheduled after reschedule
      assert_in_delta new_scheduled_time, @training_session.scheduled_for, 1.second
      assert_equal reschedule_reason, @training_session.reschedule_reason
      assert_nil @training_session.cancellation_reason # Ensure cleared
      assert_nil @training_session.no_show_notes # Ensure cleared
      assert_redirected_to trainers_training_session_url(@training_session)
      assert_equal 'Training session rescheduled successfully.', flash[:notice][:message]

      event = Event.last
      assert_equal 'training_rescheduled', event.action
      assert_equal @training_session.id, event.metadata['training_session_id']
      assert_equal @training_session.application_id, event.metadata['application_id']
      assert_not_nil event.metadata['old_scheduled_for'] # Check old_scheduled_for is in metadata
      assert_not_nil event.metadata['new_scheduled_for'] # Check new_scheduled_for is in metadata
      assert_equal reschedule_reason, event.metadata['reason']
      assert_equal @trainer, event.user
    end

    test 'reschedule should fail without scheduled_for' do
      sign_in_for_controller_test @trainer
      reschedule_reason = 'Trainer unavailable.'

      assert_no_difference('Event.count') do
        post reschedule_trainers_training_session_url(@training_session),
             params: { reschedule_reason: reschedule_reason }
      end

      @training_session.reload
      assert_equal 'scheduled', @training_session.status # Status should not change
      assert_response :unprocessable_content
      assert_includes @response.body, 'Failed to reschedule training session:' # Check for error message in body
    end

    test 'reschedule should fail without reschedule_reason' do
      sign_in_for_controller_test @trainer
      new_scheduled_time = 3.days.from_now

      assert_no_difference('Event.count') do
        post reschedule_trainers_training_session_url(@training_session),
             params: { scheduled_for: new_scheduled_time }
      end

      @training_session.reload
      assert_equal 'scheduled', @training_session.status # Status should not change
      assert_response :unprocessable_content
      assert_includes @response.body, 'Failed to reschedule training session:' # Check for error message in body
    end

  # --- Cancel Action Tests ---
    test 'cancel should update status to cancelled, set cancelled_at, cancellation_reason, and log specific event' do
      sign_in_for_controller_test @trainer
      cancellation_reason = 'Constituent cancelled.'

      assert_difference('Event.count') do
        post cancel_trainers_training_session_url(@training_session),
             params: { cancellation_reason: cancellation_reason }
      end

      @training_session.reload
      assert_equal 'cancelled', @training_session.status
      assert_not_nil @training_session.cancelled_at
      assert_equal cancellation_reason, @training_session.cancellation_reason
      assert_nil @training_session.notes # Ensure cleared
      assert_nil @training_session.no_show_notes # Ensure cleared
      assert_redirected_to trainers_training_session_url(@training_session)
      assert_equal 'Training session cancelled successfully.', flash[:notice][:message]

      event = Event.last
      assert_equal 'training_cancelled', event.action
      assert_equal @training_session.id, event.metadata['training_session_id']
      assert_equal @training_session.application_id, event.metadata['application_id']
      assert_equal cancellation_reason, event.metadata['cancellation_reason']
      assert_equal @trainer, event.user
    end

    test 'cancel should fail without cancellation_reason' do
      sign_in_for_controller_test @trainer

      assert_no_difference('Event.count') do
        post cancel_trainers_training_session_url(@training_session)
      end

      @training_session.reload
      assert_equal 'scheduled', @training_session.status # Status should not change
      assert_response :unprocessable_content
      assert_includes @response.body, 'Failed to cancel training session:' # Check for error message in body
    end

  # --- Index and Filter Action Tests ---

  # Basic reachability check
    test 'index should return success when signed in (basic check)' do
      sign_in_for_controller_test @trainer # Uses ENV['TEST_USER_ID']
      get trainers_training_sessions_url # Basic index route
      # This action should redirect if no params, but we want to check if it's reachable (not 404)
      # A 302 redirect to dashboard is expected success here, proving reachability.
      assert_response :redirect
    end

    test 'index should redirect to dashboard if no filter params' do
      sign_in_for_controller_test @trainer
      get trainers_training_sessions_url # No params
      assert_redirected_to trainers_dashboard_url
    end

    test 'index should filter sessions if filter params are present (trainer)' do
      sign_in_for_controller_test @trainer
      # Sessions are created in setup
      trainer_scheduled = @training_session
      trainer_completed = @completed_session
      other_trainer_scheduled = @other_trainer_session

      get trainers_training_sessions_url(status: 'scheduled', scope: 'mine')
      assert_response :success
      assert_equal 'mine', assigns(:current_scope)
      assert_equal 'scheduled', assigns(:current_status)
      assert_includes assigns(:training_sessions), trainer_scheduled
      assert_not_includes assigns(:training_sessions), trainer_completed
      assert_not_includes assigns(:training_sessions), other_trainer_scheduled
    end

    test 'index should filter sessions if filter params are present (admin)' do
      sign_in_for_controller_test @admin
      # Sessions are created in setup
      trainer_scheduled = @training_session
      trainer_completed = @completed_session
      other_trainer_scheduled = @other_trainer_session

      get trainers_training_sessions_url(status: 'scheduled', scope: 'all')
      assert_response :success
      assert_equal 'all', assigns(:current_scope)
      assert_equal 'scheduled', assigns(:current_status)
      assert_includes assigns(:training_sessions), trainer_scheduled
      assert_not_includes assigns(:training_sessions), trainer_completed
      assert_includes assigns(:training_sessions), other_trainer_scheduled
    end

    test 'filter should filter sessions and render index (trainer)' do
      sign_in_for_controller_test @trainer
      # Sessions are created in setup
      trainer_scheduled = @training_session
      trainer_completed = @completed_session
      other_trainer_scheduled = @other_trainer_session

      get filtered_trainers_training_sessions_url(status: 'scheduled', scope: 'mine')
      assert_response :success
      assert_template :index # Should render index template
      assert_equal 'mine', assigns(:current_scope)
      assert_equal 'scheduled', assigns(:current_status)
      assert_includes assigns(:training_sessions), trainer_scheduled
      assert_not_includes assigns(:training_sessions), trainer_completed
      assert_not_includes assigns(:training_sessions), other_trainer_scheduled
    end

    test 'filter should filter sessions and render index (admin)' do
      sign_in_for_controller_test @admin
      # Sessions are created in setup
      trainer_scheduled = @training_session
      trainer_completed = @completed_session
      other_trainer_scheduled = @other_trainer_session

      get filtered_trainers_training_sessions_url(status: 'scheduled', scope: 'all')
      assert_response :success
      assert_template :index
      assert_equal 'all', assigns(:current_scope)
      assert_equal 'scheduled', assigns(:current_status)
      assert_includes assigns(:training_sessions), trainer_scheduled
      assert_not_includes assigns(:training_sessions), trainer_completed
      assert_includes assigns(:training_sessions), other_trainer_scheduled
    end

  # Add tests for requested, scheduled, completed, needs_followup actions if they are still used directly
  # (The index/filter actions seem to be the primary way to view lists now, but double-check routes and usage)
  end
end
