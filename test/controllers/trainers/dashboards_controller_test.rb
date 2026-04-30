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

    test 'follow-up sessions exclude cancelled sessions superseded by a newer scheduled session' do
      sign_in_for_integration_test(@trainer)
      application = create(:application, :old_enough_for_new_application, user: create(:constituent))
      cancelled_session = create(:training_session, :cancelled, trainer: @trainer, application: application, created_at: 1.day.ago)
      create(:training_session, :scheduled, trainer: @trainer, application: application, created_at: Time.current)

      get trainers_dashboard_path

      assert_response :success
      assert_not_includes assigns(:followup_sessions), cancelled_session
      assert_not_includes assigns(:recent_followup_sessions), cancelled_session
    end

    test 'recent follow-up sessions are ordered by newest updated_at first' do
      sign_in_for_integration_test(@trainer)
      older_application = create(:application, :old_enough_for_new_application, user: create(:constituent))
      newer_application = create(:application, :old_enough_for_new_application, user: create(:constituent))
      older_session = create(:training_session, :cancelled, trainer: @trainer, application: older_application, updated_at: 2.days.ago)
      newer_session = create(:training_session, :no_show, trainer: @trainer, application: newer_application, updated_at: 1.hour.ago)

      get trainers_dashboard_path

      assert_response :success
      assert_equal newer_session, assigns(:recent_followup_sessions).first
      assert_equal older_session, assigns(:recent_followup_sessions).second
    end

    test 'requested and scheduled sessions render in their own open-session buckets' do
      sign_in_for_integration_test(@trainer)
      requested_application = create(:application, :old_enough_for_new_application, user: create(:constituent))
      scheduled_application = create(:application, :old_enough_for_new_application, user: create(:constituent))
      requested_session = create(:training_session, :requested, trainer: @trainer, application: requested_application, created_at: 1.day.ago)
      scheduled_session = create(:training_session, :scheduled, trainer: @trainer, application: scheduled_application, created_at: Time.current)

      get trainers_dashboard_path

      assert_response :success
      assert_includes assigns(:requested_sessions), requested_session
      assert_includes assigns(:scheduled_sessions), scheduled_session
      assert_includes assigns(:upcoming_sessions), scheduled_session
    end

    test 'trainer dashboard and scheduled filter show only assigned sessions' do
      sign_in_for_integration_test(@trainer)

      get trainers_dashboard_path

      assert_response :success
      assert_includes assigns(:scheduled_sessions), @session
      assert_not_includes assigns(:scheduled_sessions), @other_session
      assert_includes assigns(:upcoming_sessions), @session
      assert_not_includes assigns(:upcoming_sessions), @other_session
      assert_includes @response.body, @constituent.full_name

      get trainers_dashboard_path(filter: 'scheduled')

      assert_response :success
      assert_includes assigns(:filtered_sessions), @session
      assert_not_includes assigns(:filtered_sessions), @other_session
    end

    test 'admin dashboard surfaces scheduled sessions assigned to the admin separately' do
      sign_in_for_integration_test(@admin)
      admin_constituent = create(:constituent, first_name: 'Admin', last_name: 'Training')
      admin_application = create(:application, :old_enough_for_new_application, user: admin_constituent)
      admin_session = create(:training_session, :scheduled, trainer: @admin, application: admin_application)

      get trainers_dashboard_path

      assert_response :success
      assert_includes assigns(:scheduled_sessions), @session
      assert_includes assigns(:scheduled_sessions), @other_session
      assert_includes assigns(:my_scheduled_sessions), admin_session
      assert_not_includes assigns(:my_scheduled_sessions), @session
      assert_select 'h2', text: 'My Upcoming Training Sessions', count: 1
      assert_select 'a', text: 'My Scheduled', count: 1
      assert_select 'a', text: 'View My Scheduled', count: 1
    end

    test 'scheduled filter hides default dashboard tables' do
      sign_in_for_integration_test(@trainer)

      get trainers_dashboard_path(filter: 'scheduled')

      assert_response :success
      assert_select 'h2', text: 'Upcoming Training Sessions', count: 0
      assert_select 'h2', text: 'Needs Scheduling', count: 0
      assert_select 'h2', text: 'Scheduled Training Sessions', count: 1
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
