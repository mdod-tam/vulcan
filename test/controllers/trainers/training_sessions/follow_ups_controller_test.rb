# frozen_string_literal: true

require 'test_helper'

module Trainers
  module TrainingSessions
    class FollowUpsControllerTest < ActionDispatch::IntegrationTest
      setup do
        Policy.stubs(:max_training_sessions).returns(4)
        @trainer = create(:trainer)
        @application = create(:application, :approved, :with_all_proofs, application_date: Date.current, assigned_trainer: @trainer)
        @source = create(:training_session, :cancelled, application: @application, trainer: @trainer,
                                                        internal_notes: 'Retained private history')
        sign_in_for_controller_test(@trainer)
      end

      test 'follow-up form starts blank preserves all fields on error and creates one agreed appointment on retry' do
        get trainers_training_session_path(@source)
        assert_response :success
        assert_select '#follow_up_scheduled_for[value]', count: 0
        attempted = { scheduled_for: '', location: 'Attempted library', reschedule_reason: 'Agreed follow-up', internal_notes: 'Preparation for next visit' }
        2.times do
          assert_no_difference ['TrainingSession.count', 'Event.count'] do
            post trainers_training_session_follow_up_path(@source), params: attempted
          end
          assert_response :unprocessable_content
          assert_select('#follow_up_scheduled_for') { |nodes| assert_equal '', nodes.sole['value'].to_s }
          assert_select('#follow_up_location') { |nodes| assert_equal attempted[:location], nodes.sole['value'].to_s }
          assert_select '#follow_up_reschedule_reason', text: attempted[:reschedule_reason]
          assert_select '#follow_up_internal_notes', text: attempted[:internal_notes]
        end
        original = @source.reload.attributes
        assert_difference ['TrainingSession.count', "Event.where(action: 'training_followup_scheduled').count"], 1 do
          post trainers_training_session_follow_up_path(@source), params: attempted.merge(scheduled_for: 3.days.from_now, internal_notes: '')
        end
        created = @application.training_sessions.assigned_or_scheduled.sole
        assert_response :see_other
        assert_redirected_to trainers_training_session_path(created)
        assert_equal '', created.internal_notes
        assert_equal 'Attempted library', created.location
        assert_equal 'Agreed follow-up', created.reschedule_reason
        assert_equal original, @source.reload.attributes
        assert_not @application.training_sessions.exists?(status: :requested)
      end

      test 'a missing follow-up reason has a linked field error and preserves the agreed date' do
        date = 3.days.from_now.strftime('%Y-%m-%dT%H:%M')
        post trainers_training_session_follow_up_path(@source), params: { scheduled_for: date, reschedule_reason: '' }

        assert_response :unprocessable_content
        assert_select '#follow_up_reschedule_reason[aria-invalid=true]'
        assert_select '#follow-up-errors a[href="#follow_up_reschedule_reason"]'
        assert_select('#follow_up_scheduled_for') { |nodes| assert_equal date, nodes.sole['value'] }
        assert_equal 0, @application.training_sessions.assigned_or_scheduled.count
      end

      test 'the existing open appointment blocks another follow-up even below quota' do
        create(:training_session, :scheduled, application: @application, trainer: @trainer)
        assert_no_difference ['TrainingSession.count', 'Event.count'] do
          post trainers_training_session_follow_up_path(@source), params: valid_params
        end
        assert_response :unprocessable_content
        assert_equal 1, @application.training_sessions.assigned_or_scheduled.count
      end

      test 'a removed trainer cannot schedule from their historical cancellation' do
        assert @application.unassign_trainer!(actor: create(:admin))
        assert_no_difference ['TrainingSession.count', 'Event.count'] do
          post trainers_training_session_follow_up_path(@source), params: valid_params
        end
        assert_response :not_found
        assert_equal 0, @application.training_sessions.assigned_or_scheduled.count
      end

      test 'another trainer and a completed report cannot use the follow-up operation' do
        sign_in_for_controller_test(create(:trainer))
        post trainers_training_session_follow_up_path(@source), params: valid_params
        assert_response :not_found

        sign_in_for_controller_test(@trainer)
        report = create(:training_session, :completed, application: @application, trainer: @trainer)
        assert_no_difference ['TrainingSession.count', 'Event.count'] do
          post trainers_training_session_follow_up_path(report), params: valid_params
        end
        assert_response :unprocessable_content
        assert report.reload.status_completed?
      end

      private

      def valid_params
        { scheduled_for: 3.days.from_now, reschedule_reason: 'Agreed follow-up' }
      end
    end
  end
end
