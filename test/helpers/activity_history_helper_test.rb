# frozen_string_literal: true

require 'test_helper'

class ActivityHistoryHelperTest < ActionView::TestCase
  test 'training rescheduling shows structural dates without private reason or note bodies' do
    event = Event.new(action: 'training_rescheduled', metadata: {
                        old_scheduled_for: 2.days.from_now.iso8601,
                        new_scheduled_for: 3.days.from_now.iso8601,
                        reason: 'PRIVATE TRAINING SENTINEL', reschedule_reason: 'PRIVATE TRAINING SENTINEL',
                        notes: 'PRIVATE TRAINING SENTINEL', internal_notes: 'PRIVATE TRAINING SENTINEL'
                      })

    assert_equal 'Training Rescheduled', activity_label(event)
    assert_includes activity_detail(event), 'From '
    assert_includes activity_detail(event), 'To '
    assert_not_includes activity_detail(event), 'PRIVATE TRAINING SENTINEL'
  end

  test 'training follow-up shows the agreed date without private reason or notes' do
    event = Event.new(action: 'training_followup_scheduled', metadata: {
                        scheduled_for: 3.days.from_now.iso8601,
                        reason: 'PRIVATE TRAINING SENTINEL', notes: 'PRIVATE TRAINING SENTINEL'
                      })

    assert_equal 'Follow-up Training Scheduled', activity_label(event)
    assert_includes activity_detail(event), 'Follow-up scheduled for'
    assert_not_includes activity_detail(event), 'PRIVATE TRAINING SENTINEL'
  end

  test 'training cancellation distinguishes its initiator from the recorder without exposing the reason' do
    actor = build(:admin, first_name: 'Ada', last_name: 'Recorder')
    event = Event.new(action: 'training_cancelled', user: actor, metadata: {
                        cancellation_initiator: 'constituent', cancellation_reason: 'PRIVATE TRAINING SENTINEL',
                        notes: 'PRIVATE TRAINING SENTINEL'
                      })

    assert_equal 'Cancelled by constituent', activity_detail(event)
    assert_equal 'Ada Recorder', activity_actor_name(event)
    assert_not_includes activity_detail(event), 'PRIVATE TRAINING SENTINEL'
  end

  test 'training completion separates actual and submitted timestamps and reads only structural report facts' do
    actual_time = 1.hour.ago
    submitted_time = Time.current
    event = Event.new(action: 'training_completed', metadata: {
                        completed_at: actual_time.iso8601, report_submitted_at: submitted_time.iso8601,
                        duration_hours: '1.25', product_trained_on_id: 123,
                        product_trained_on: 'PRIVATE TRAINING SENTINEL', constituent_summary: 'PRIVATE TRAINING SENTINEL',
                        notes: 'PRIVATE TRAINING SENTINEL', internal_notes: 'PRIVATE TRAINING SENTINEL'
                      })

    detail = activity_detail(event)
    assert_includes detail, "Actual completion: #{I18n.l(actual_time, format: :long)}"
    assert_includes detail, "Report submitted: #{I18n.l(submitted_time, format: :long)}"
    assert_includes detail, 'Duration: 1.25 hours'
    assert_includes detail, 'Product ID: 123'
    assert_not_includes detail, 'PRIVATE TRAINING SENTINEL'
  end

  test 'training no-show and scheduling ignore note bodies and localize their structural descriptions' do
    I18n.with_locale(:es) do
      event = Event.new(action: 'training_no_show', metadata: { no_show_notes: 'PRIVATE TRAINING SENTINEL' })
      assert_equal 'Marcada como ausencia', activity_detail(event)
      event.action = 'training_scheduled'
      event.metadata = { scheduled_for: 3.days.from_now.iso8601, notes: 'PRIVATE TRAINING SENTINEL', internal_notes: 'PRIVATE TRAINING SENTINEL' }
      assert_includes activity_detail(event), 'Programada para'
      assert_not_includes activity_detail(event), 'PRIVATE TRAINING SENTINEL'
    end
  end

  test 'Spanish activity table has localized fallback labels and a keyboard reachable scroll region' do
    I18n.with_locale(:es) do
      event = Event.new(action: 'training_missed', created_at: Time.current, metadata: {})

      render partial: 'shared/activity_history', locals: { activity_logs: [event], show_subject: true }

      assert_select 'h2', text: 'Historial de actividad'
      assert_select 'div[role=region][tabindex="0"][aria-label="Tabla desplazable del historial de actividad"]' do
        assert_select 'table[aria-labelledby="activity-history-heading"]'
      end
      assert_select 'th', text: 'Fecha'
      assert_select 'th', text: 'Usuario'
      assert_select 'th', text: 'Detalles'
      assert_equal 'Ausencia', activity_label(event)
      assert_equal 'Sistema', activity_actor_name(event)
      assert_equal 'Persona participante desconocida', activity_subject_name(event)
    end
  end

  test 'Spanish empty activity table does not fall back to English copy' do
    I18n.with_locale(:es) do
      render partial: 'shared/activity_history', locals: { activity_logs: [] }

      assert_select 'td', text: 'Aún no se ha registrado actividad.'
    end
  end

  test 'formats known evaluation actions' do
    event = Event.new(
      action: 'evaluation_completed',
      metadata: {
        evaluation_date: Time.current.iso8601,
        products_tried_count: 2,
        recommended_products_count: 1,
        recommended_product_names: ['iPad Air']
      }
    )

    assert_equal 'Evaluation Completed', activity_label(event)
    assert_includes activity_detail(event), 'Products tried: 2'
    assert_includes activity_detail(event), 'iPad Air'
  end

  test 'formats application assignment source labels' do
    event = Event.new(action: 'evaluator_assigned', metadata: { evaluator_name: 'Ada Evaluator' })

    assert_equal 'Evaluator Assigned', activity_label(event)
    assert_equal 'Application', activity_source_label(event)
    assert_equal 'Evaluator Ada Evaluator assigned', activity_detail(event)
  end

  test 'distinguishes the appointment and report timestamps from the scheduled time' do
    event = Event.new(action: 'evaluation_completed', metadata: {
                        evaluation_date: 2.days.from_now.iso8601,
                        appointment_completed_at: 1.hour.ago.iso8601,
                        report_submitted_at: Time.current.iso8601
                      })

    detail = activity_detail(event)
    assert_includes detail, 'Scheduled for'
    assert_includes detail, 'Appointment completed'
    assert_includes detail, 'Report submitted'
  end

  test 'legacy evaluation history does not label a scheduled date as completion' do
    event = Event.new(action: 'evaluation_completed', metadata: { evaluation_date: 2.days.from_now.iso8601 })

    assert_includes activity_detail(event), 'Scheduled for'
    assert_not_includes activity_detail(event), 'Appointment completed'
    assert_not_includes activity_detail(event), 'Report submitted'
  end

  test 'handles missing metadata gracefully' do
    event = Event.new(action: 'evaluation_scheduled', metadata: {})

    assert_equal 'No additional details recorded', activity_detail(event)
  end

  test 'uses actor name when available' do
    user = create(:admin, first_name: 'Ada', last_name: 'Lovelace')
    event = Event.new(action: 'evaluation_scheduled', user: user, metadata: {})

    assert_equal 'Ada Lovelace', activity_actor_name(event)
  end

  test 'uses evaluation constituent as activity subject' do
    constituent = create(:constituent, first_name: 'Alice', last_name: 'Doe')
    evaluation = create(:evaluation, constituent: constituent)
    event = Event.new(action: 'evaluation_scheduled', auditable: evaluation, metadata: {})

    assert_equal 'Alice Doe', activity_subject_name(event)
  end

  test 'uses application constituent as activity subject for assignment events' do
    constituent = create(:constituent, first_name: 'Pat', last_name: 'Portal')
    application = create(:application, :old_enough_for_new_application, user: constituent)
    event = Event.new(action: 'evaluator_assigned', auditable: application, metadata: {})

    assert_equal 'Pat Portal', activity_subject_name(event)
  end

  test 'falls back to evaluation metadata for activity subject' do
    constituent = create(:constituent, first_name: 'Morgan', last_name: 'Metadata')
    evaluation = create(:evaluation, constituent: constituent)
    event = Event.new(action: 'evaluation_completed', metadata: { evaluation_id: evaluation.id.to_s })

    assert_equal 'Morgan Metadata', activity_subject_name(event)
  end
end
