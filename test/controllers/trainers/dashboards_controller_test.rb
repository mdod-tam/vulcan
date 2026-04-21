# frozen_string_literal: true

require 'test_helper'

module Trainers
  class DashboardsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @trainer = create(:trainer)
      @other_trainer = create(:trainer)
      @admin = create(:admin)
      @constituent = create(:constituent, first_name: 'Training', last_name: 'Participant')
      @other_constituent = create(:constituent, first_name: 'Other', last_name: 'Participant')
      @application = create(:application, :old_enough_for_new_application, user: @constituent)
      @other_application = create(:application, :old_enough_for_new_application, user: @other_constituent)
      @session = create(:training_session, :scheduled, trainer: @trainer, application: @application)
      @other_session = create(:training_session, :scheduled, trainer: @other_trainer, application: @other_application)
    end

    test 'trainer sees only their own recent activity' do
      sign_in_for_integration_test(@trainer)
      own_event = create_training_event(@session, 'Own session activity')
      other_event = create_training_event(@other_session, 'Other session activity')

      get trainers_dashboard_path

      assert_response :success
      assert_includes assigns(:activity_logs), own_event
      assert_not_includes assigns(:activity_logs), other_event
      assert_includes @response.body, 'Own session activity'
      assert_not_includes @response.body, 'Other session activity'
      assert_includes @response.body, 'Constituent'
      assert_includes @response.body, @constituent.full_name
      assert_not_includes @response.body, @other_constituent.full_name
    end

    test 'admin sees broader recent training activity' do
      sign_in_for_integration_test(@admin)
      own_event = create_training_event(@session, 'Trainer session activity')
      other_event = create_training_event(@other_session, 'Other trainer activity')

      get trainers_dashboard_path

      assert_response :success
      assert_includes assigns(:activity_logs), own_event
      assert_includes assigns(:activity_logs), other_event
    end

    test 'recent activity feed is limited' do
      sign_in_for_integration_test(@trainer)
      11.times do |index|
        create_training_event(@session, "Activity #{index}", created_at: index.minutes.ago)
      end

      get trainers_dashboard_path

      assert_response :success
      assert_equal 10, assigns(:activity_logs).size
    end

    private

    def create_training_event(training_session, notes, created_at: Time.current)
      Event.create!(
        user: training_session.trainer,
        action: 'training_scheduled',
        auditable: training_session,
        metadata: {
          training_session_id: training_session.id,
          notes: notes,
          scheduled_for: training_session.scheduled_for&.iso8601
        },
        created_at: created_at
      )
    end
  end
end
