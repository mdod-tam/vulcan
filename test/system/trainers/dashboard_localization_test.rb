# frozen_string_literal: true

require 'application_system_test_case'

module Trainers
  class DashboardLocalizationTest < ApplicationSystemTestCase
    test 'Spanish narrow dashboard exposes full request counts and all overdue appointments with accessible activity' do
      trainer = create(:trainer, locale: 'es')
      requests = Array.new(11) do |index|
        application = covered_application(trainer, "Solicitud #{index + 1}")
        create(:training_session, :completed, trainer: trainer, application: application)
        application.update!(training_requested_at: Time.current)
        application
      end
      overdue = []
      travel_to 2.days.ago do
        11.times do |index|
          application = covered_application(trainer, "Cita #{index + 1}")
          overdue << create(:training_session, :scheduled, trainer: trainer, application: application)
        end
      end
      Event.create!(user: trainer, action: 'training_scheduled', auditable: overdue.first,
                    metadata: { scheduled_for: overdue.first.scheduled_for.iso8601, notes: 'PRIVATE ACTIVITY SENTINEL' })
      system_test_sign_in(trainer)
      page.current_window.resize_to(375, 812)

      visit trainers_dashboard_path

      assert_selector 'h1', text: 'Panel de capacitación'
      assert_selector 'h3#card-needs-scheduling + p', text: /11\s+elementos pendientes de programación/
      requests.each { |application| assert_text application.user.full_name }
      within 'section[aria-labelledby="overdue-training-heading"]' do
        assert_text 'Tiene 11 citas pasadas por actualizar. Cuéntenos qué pasó.'
        assert_text 'Se muestran 10 de 11 citas.'
        assert_link 'Ver su lista de citas', href: trainers_training_sessions_path(status: 'scheduled')
      end
      assert_text 'No hay próximas sesiones de capacitación programadas.'
      assert_text 'No hay sesiones de capacitación pendientes de seguimiento.'
      assert_selector '#activity-history-heading', text: 'Actividad reciente'
      assert_selector 'table[aria-labelledby="activity-history-heading"] th', text: /Detalles/i
      assert_text 'Capacitación programada'
      assert_no_text 'PRIVATE ACTIVITY SENTINEL'
      assert page.evaluate_script('document.documentElement.scrollWidth <= window.innerWidth'), 'The narrow dashboard overflows horizontally.'
      take_screenshot('trainer-dashboard-spanish-counts-and-overdue-narrow', html: true, full: true)

      region = find('div[role=region][data-activity-history-scroll][tabindex="0"]')
      region.send_keys(:right)
      assert_selector 'div[role=region][data-activity-history-scroll]:focus'
      assert region.evaluate_script('this.scrollWidth > this.clientWidth'), 'The activity table should scroll within its narrow region.'
      assert region.evaluate_script('this.scrollLeft > 0'), 'The activity table should be scrollable with the keyboard.'
      take_screenshot('trainer-dashboard-spanish-activity-scroll-narrow', html: true, full: true)

      within 'section[aria-labelledby="overdue-training-heading"]' do
        click_link 'Ver su lista de citas'
      end
      assert_selector 'h1', text: 'Sesiones de capacitación programadas'
      overdue.each { |session| assert_link href: trainers_training_session_path(session) }
      assert_no_text 'Confirmed'
      assert_no_text 'Scheduled'
    ensure
      page.current_window.resize_to(1200, 900)
    end

    test 'Spanish dashboard explains an empty activity history' do
      trainer = create(:trainer, locale: 'es')
      system_test_sign_in(trainer)
      page.current_window.resize_to(375, 812)

      visit trainers_dashboard_path

      assert_selector 'h1', text: 'Panel de capacitación'
      assert_text 'No hay sesiones pendientes de programación.'
      assert_text 'Aún no se ha registrado actividad.'
      assert_no_text 'No activity has been recorded yet.'
      assert page.evaluate_script('document.documentElement.scrollWidth <= window.innerWidth')
      take_screenshot('trainer-dashboard-spanish-empty-activity-narrow', html: true, full: true)
    ensure
      page.current_window.resize_to(1200, 900)
    end

    private

    def covered_application(trainer, first_name)
      constituent = create(:constituent, first_name: first_name, last_name: 'Participante de capacitación')
      create(:application, :approved, :with_all_proofs, user: constituent, assigned_trainer: trainer, application_date: Date.current)
    end
  end
end
