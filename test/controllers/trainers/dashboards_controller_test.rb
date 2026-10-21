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
      @application = create(:application, :approved, :with_all_proofs, user: @constituent, application_date: Date.current, assigned_trainer: @trainer)
      @other_application = create(:application, :approved, :with_all_proofs, user: @other_constituent, application_date: Date.current, assigned_trainer: @other_trainer)
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
      assert_includes @response.body, 'Training Scheduled'
      assert_not_includes @response.body, 'Own session activity'
      assert_not_includes @response.body, 'Other session activity'
      assert_includes @response.body, 'Constituent'
      assert_includes @response.body, @constituent.full_name
      assert_not_includes @response.body, @other_constituent.full_name
      assert_select 'a[href=?]', admin_applications_path, text: 'Back to Dashboard', count: 0
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
      application = covered_application
      cancelled_session = create(:training_session, :cancelled, trainer: @trainer, application: application, created_at: 1.day.ago)
      create(:training_session, :scheduled, trainer: @trainer, application: application, created_at: Time.current)

      get trainers_dashboard_path

      assert_response :success
      assert_not_includes assigns(:followup_sessions), cancelled_session
      assert_not_includes assigns(:recent_followup_sessions), cancelled_session
    end

    test 'recent follow-up sessions are ordered by newest updated_at first' do
      sign_in_for_integration_test(@trainer)
      older_application = covered_application
      newer_application = covered_application
      older_session = create(:training_session, :cancelled, trainer: @trainer, application: older_application, updated_at: 2.days.ago)
      newer_session = create(:training_session, :no_show, trainer: @trainer, application: newer_application, updated_at: 1.hour.ago)

      get trainers_dashboard_path

      assert_response :success
      assert_equal newer_session, assigns(:recent_followup_sessions).first
      assert_equal older_session, assigns(:recent_followup_sessions).second
    end

    test 'requested and scheduled sessions render in their own open-session buckets' do
      sign_in_for_integration_test(@trainer)
      requested_application = covered_application
      scheduled_application = covered_application
      requested_session = create(:training_session, :requested, trainer: @trainer, application: requested_application, created_at: 1.day.ago)
      scheduled_session = create(:training_session, :scheduled, trainer: @trainer, application: scheduled_application, created_at: Time.current)

      get trainers_dashboard_path

      assert_response :success
      assert_includes assigns(:requested_sessions), requested_session
      assert_includes assigns(:scheduled_sessions), scheduled_session
      assert_includes assigns(:upcoming_sessions), scheduled_session
    end

    test 'scheduled sessions keep legitimate appointments on separate applications isolated by current trainer' do
      sign_in_for_integration_test(@trainer)
      additional_application = covered_application
      additional_session = create(:training_session, :scheduled, trainer: @trainer, application: additional_application, scheduled_for: 2.days.from_now)

      get trainers_dashboard_path

      assert_response :success
      assert_equal [@session.id, additional_session.id].sort, assigns(:scheduled_sessions).pluck(:id).sort
      assert_includes assigns(:upcoming_sessions), @session
      assert_includes assigns(:upcoming_sessions), additional_session
      assert_not_includes assigns(:scheduled_sessions), @other_session
      assert_equal 1, @application.training_sessions.assigned_or_scheduled.count
      assert_equal 1, additional_application.training_sessions.assigned_or_scheduled.count
    end

    test 'past outcomes are separated from upcoming scheduled and confirmed appointments' do
      sign_in_for_integration_test(@trainer)
      later = create(:training_session, :scheduled, trainer: @trainer, application: covered_application, scheduled_for: 3.days.from_now)
      confirmed = create(:training_session, :scheduled, status: :confirmed, trainer: @trainer, application: covered_application, scheduled_for: 4.days.from_now)

      travel_to 2.days.from_now do
        get trainers_dashboard_path

        assert_response :success
        assert_includes assigns(:overdue_sessions), @session
        assert_not_includes assigns(:upcoming_sessions), @session
        assert_equal [later.id, confirmed.id], assigns(:upcoming_sessions).pluck(:id)
        assert_includes assigns(:scheduled_sessions), confirmed
        assert_select 'h2', text: 'Past appointments to update'
        assert_select 'section[aria-labelledby="overdue-training-heading"]' do
          assert_select 'p', text: 'You have 1 past appointment to update. Tell us what happened.'
          assert_select 'p', text: /Showing/, count: 0
          assert_select 'a', text: 'Update appointment'
        end
        assert_select 'section[aria-labelledby="overdue-training-heading"] a[href=?]', trainers_training_session_path(@session)
        assert_select 'section[aria-labelledby="overdue-training-heading"] a[href=?][aria-label=?]',
                      trainers_training_session_path(@session), "Update appointment for #{@constituent.full_name}"
        assert_select 'section[aria-labelledby="overdue-training-heading"] a[href=?]', trainers_training_session_path(@other_session), count: 0
      end
    end

    test 'removed and reassigned trainers keep completed authorship without current open or follow-up work' do
      report = create(:training_session, :completed, trainer: @trainer, application: @application, created_at: 2.days.ago)
      assert @application.unassign_trainer!(actor: @admin)
      assert @application.assign_trainer!(@other_trainer, actor: @admin)
      replacement = @application.latest_training_session
      sign_in_for_integration_test(@trainer)

      get trainers_dashboard_path

      assert_response :success
      assert_includes assigns(:completed_sessions), report
      assert_not_includes assigns(:requested_sessions), replacement
      assert_not_includes assigns(:followup_sessions), @session
      assert_empty assigns(:scheduled_sessions)
      assert_select 'a[href=?]', trainers_training_session_path(report)
      assert_select 'a[href=?]', trainers_training_session_path(replacement), count: 0
    end

    test 'covered requests hand off to the current trainer without exposing administrative application links' do
      application, report = requested_covered_application(@trainer)
      other_application, = requested_covered_application(@other_trainer)
      sign_in_for_integration_test(@trainer)

      get trainers_dashboard_path

      assert_response :success
      assert_includes assigns(:pending_training_requests), application
      assert_not_includes assigns(:pending_training_requests), other_application
      assert_select '#needs-scheduling-section tr', text: /#{Regexp.escape(application.user.full_name)}/ do
        assert_select 'span', text: 'Awaiting Scheduling'
        assert_select 'a[href=?][aria-label=?]', trainers_training_session_path(report),
                      "Review request and arrange next appointment for #{application.constituent_full_name}", text: 'Review request and arrange next appointment'
        assert_select 'a[href=?]', admin_application_path(application), count: 0
      end
      assert_select 'a[href=?]', admin_application_path(application), count: 0
      assert_select '#covered-requests-heading', count: 0
    end

    test 'administrator requests distinguish own trainer handoff covered oversight and uncovered assignment' do
      own_application, own_report = requested_covered_application(@admin)
      covered_application, = requested_covered_application(@trainer)
      uncovered = create(:application, :approved, :with_all_proofs, user: create(:constituent, first_name: 'Uncovered', last_name: 'Participant'),
                                                                    application_date: Date.current, training_requested_at: Time.current)
      sign_in_for_integration_test(@admin)

      get trainers_dashboard_path

      assert_select '#needs-scheduling-section tr', text: /#{Regexp.escape(own_application.user.full_name)}/ do
        assert_select 'a[href=?][aria-label=?]', trainers_training_session_path(own_report),
                      "Review request and arrange next appointment for #{own_application.constituent_full_name}", text: 'Review request and arrange next appointment'
      end
      assert_select '#needs-scheduling-section tr', text: /#{Regexp.escape(covered_application.user.full_name)}/ do
        assert_select 'span', text: 'Awaiting Scheduling'
        assert_select 'a[href=?][aria-label=?]', admin_application_path(covered_application),
                      "Review trainer coverage for #{covered_application.constituent_full_name}", text: 'Review trainer coverage'
      end
      assert_select '#needs-scheduling-section tr', text: /#{Regexp.escape(uncovered.user.full_name)}/ do
        assert_select 'span', text: 'Awaiting Assignment'
        assert_select 'a[href=?][aria-label=?]', admin_application_path(uncovered),
                      "Visit App And Assign Trainer for #{uncovered.constituent_full_name}", text: 'Visit App And Assign Trainer'
      end
    end

    test 'admin dashboard surfaces scheduled sessions assigned to the admin separately' do
      sign_in_for_integration_test(@admin)
      admin_constituent = create(:constituent, first_name: 'Admin', last_name: 'Training')
      admin_application = covered_application(trainer: @admin, user: admin_constituent)
      admin_session = create(:training_session, :scheduled, trainer: @admin, application: admin_application)

      get trainers_dashboard_path

      assert_response :success
      assert_includes assigns(:scheduled_sessions), @session
      assert_includes assigns(:scheduled_sessions), @other_session
      assert_includes assigns(:my_scheduled_sessions), admin_session
      assert_not_includes assigns(:my_scheduled_sessions), @session
      assert_select 'h2', text: 'My Upcoming Training Sessions', count: 1
      assert_select 'a', text: 'View My Scheduled', count: 1
    end

    test 'needs scheduling counts every pending application request and displays requests beyond ten' do
      applications = Array.new(12) { requested_covered_application(@trainer).first }
      assigned_session = create(:training_session, :requested, trainer: @trainer, application: covered_application)
      sign_in_for_integration_test(@trainer)

      get trainers_dashboard_path

      assert_response :success
      assert_equal 13, assigns(:needs_scheduling_count)
      assert_equal applications.map(&:id).sort, assigns(:pending_training_requests).pluck(:id).sort
      applications.each do |application|
        assert_select '#needs-scheduling-section tr', text: /#{Regexp.escape(application.user.full_name)}/
      end
      assert_select '#needs-scheduling-section a[href=?]', trainers_training_session_path(assigned_session)
      assert_select '#needs-scheduling-section a[href=?]', trainers_training_sessions_path(status: 'requested'), text: 'View all assigned sessions'
    end

    test 'scheduled count and links include all past appointments while previews show honest limits' do
      overdue = Array.new(12) do
        create(:training_session, :scheduled, trainer: @trainer, application: covered_application)
      end
      future = create(:training_session, :scheduled, trainer: @trainer, application: covered_application, scheduled_for: 4.days.from_now)

      travel_to 2.days.from_now do
        sign_in_for_integration_test(@trainer)
        get trainers_dashboard_path

        assert_response :success
        assert_equal 14, assigns(:scheduled_sessions_count)
        assert_equal 13, assigns(:overdue_sessions_count)
        assert_equal 10, assigns(:overdue_sessions_display).size
        assert_equal [future.id], assigns(:upcoming_sessions).pluck(:id)
        assert_select 'section[aria-labelledby="overdue-training-heading"]' do
          assert_select 'p', text: 'You have 13 past appointments to update. Tell us what happened.'
          assert_select 'p', text: 'Showing 10 of 13 appointments.'
          assert_select 'a[href=?]', trainers_training_sessions_path(status: 'scheduled'), text: 'View your appointment list'
        end
        assert_select 'h3#card-scheduled + p', text: /14 scheduled sessions/
        assert_select 'a[href=?]', trainers_training_sessions_path(status: 'scheduled'), text: 'View scheduled'

        get trainers_training_sessions_path(status: 'scheduled')

        assert_response :success
        (overdue + [@session, future]).each do |session|
          assert_select 'a[href=?]', trainers_training_session_path(session)
        end
        assert_not_includes assigns(:training_sessions), @other_session
      end
    end

    test 'administrator upcoming preview excludes past own appointments while own count links to all scheduled' do
      own_past = create(:training_session, :scheduled, trainer: @admin, application: covered_application(trainer: @admin))
      own_future = create(:training_session, :scheduled, trainer: @admin, application: covered_application(trainer: @admin), scheduled_for: 4.days.from_now)

      travel_to 2.days.from_now do
        sign_in_for_integration_test(@admin)
        get trainers_dashboard_path

        assert_equal 2, assigns(:my_scheduled_sessions_count)
        assert_equal [own_future.id], assigns(:my_scheduled_sessions_display).pluck(:id)
        assert_not_includes assigns(:my_scheduled_sessions_display), own_past
        assert_select 'a[href=?]', trainers_training_sessions_path(scope: 'mine', status: 'scheduled'), text: 'My scheduled'
      end
    end

    test 'Spanish scheduling links identify the constituent for both new and follow-up requests' do
      @trainer.update!(locale: 'es')
      application, report = requested_covered_application(@trainer)
      requested = create(:training_session, :requested, trainer: @trainer, application: covered_application)
      sign_in_for_integration_test(@trainer)

      get trainers_dashboard_path

      assert_response :success
      assert_select '#needs-scheduling-section a[href=?][aria-label=?]', trainers_training_session_path(report),
                    "Revisar la solicitud y acordar la próxima cita de #{application.constituent_full_name}", text: 'Revisar la solicitud y acordar la próxima cita'
      assert_select '#needs-scheduling-section a[href=?][aria-label=?]', trainers_training_session_path(requested),
                    "Ver/Programar para #{requested.application.constituent_full_name}", text: 'Ver/Programar'
    end

    test 'Spanish viewer receives translated dashboard status activity columns and empty states' do
      @trainer.update!(locale: 'es')
      create_training_event(@session, 'PRIVATE SENTINEL')
      create(:training_session, :scheduled, status: :confirmed, trainer: @trainer, application: covered_application)
      sign_in_for_integration_test(@trainer)

      get trainers_dashboard_path

      assert_response :success
      assert_select 'h1', text: 'Panel de capacitación'
      assert_select 'h3#card-scheduled', text: 'Sesiones programadas'
      assert_select 'h2#upcoming-sessions-table-heading', text: 'Próximas sesiones de capacitación'
      assert_select '#upcoming-sessions-section span', text: 'Estado: Programada', count: 2
      assert_select '#activity-history-heading', text: 'Actividad reciente'
      assert_select 'table[aria-labelledby="activity-history-heading"] th', text: 'Detalles'
      assert_select 'div[role=region][tabindex="0"][aria-label="Tabla desplazable del historial de actividad"]'
      assert_includes response.body, 'Capacitación programada'
      assert_includes response.body, 'No hay sesiones de capacitación pendientes de seguimiento.'
      assert_not_includes response.body, 'PRIVATE SENTINEL'
      assert_not_includes response.body, 'translation_missing'
    end

    private

    def covered_application(trainer: @trainer, user: nil)
      @covered_application_count = @covered_application_count.to_i + 1
      user ||= create(:constituent, first_name: "Covered #{@covered_application_count}", last_name: 'Participant')
      create(:application, :approved, :with_all_proofs, user: user, application_date: Date.current, assigned_trainer: trainer)
    end

    def requested_covered_application(trainer)
      application = covered_application(trainer: trainer)
      report = create(:training_session, :completed, application: application, trainer: trainer, created_at: 1.day.ago, completed_at: 12.hours.ago)
      result = Applications::TrainingRequestService.new(application: application, current_user: application.user).call
      assert result.success?, result.message
      [application, report]
    end

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
