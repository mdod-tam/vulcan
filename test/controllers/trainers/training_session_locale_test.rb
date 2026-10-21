# frozen_string_literal: true

require 'test_helper'

module Trainers
  class TrainingSessionLocaleTest < ActionDispatch::IntegrationTest
    test 'the authenticated trainer locale applies to the full appointment and report entry screen' do
      trainer = create(:trainer, locale: 'es')
      application = create(:application, :approved, :with_all_proofs, assigned_trainer: trainer)
      session = create(:training_session, :scheduled, trainer: trainer, application: application)
      sign_in_for_integration_test(trainer)

      get trainers_training_session_path(session)

      assert_response :success
      assert_select 'h1', text: "Detalles de la sesión de capacitación n.º #{session.appointment_number}"
      assert_select 'h2', text: 'Preparación y contacto para la coordinación'
      assert_select 'h2#session-actions-heading', text: '¿Qué ocurrió?'
      assert_select '[data-training-outcome-target=status][role=status][aria-live=polite]', text: ''
      assert_select '[data-controller=training-outcome][data-training-outcome-message-value=?]',
                    'Se muestra el formulario de «__ACTION__». Complete los datos y guarde los cambios.'
      assert_select 'dt', text: 'Correo electrónico de contacto'
      assert_select 'p', text: 'Idioma preferido: inglés'
      assert_not_includes response.body, 'Translation missing'
      assert_not_includes response.body, '{:asl'
      assert_includes response.body, 'No proporcionado'
      assert_select 'label[for=complete_constituent_summary]', text: /Resumen compartido de la sesión/
      assert_select 'label', text: 'Lugar o instrucciones de la reunión (compartidos)'
      assert_select 'option', text: 'Reprogramar a petición de la persona'
      assert_select 'input[type=submit][value="Guardar informe completado"]'
      assert_select 'option', text: 'español'
      assert_select 'span', text: 'Programada'
      assert_select 'button[data-training-duration-confirmation-target=noButton]', text: I18n.t('trainer_workflow.confirmation.no', locale: :es)
      assert_select 'button[data-training-duration-confirmation-target=yesButton]', text: I18n.t('trainer_workflow.confirmation.yes', locale: :es)
      assert_select '.translation_missing', count: 0
      assert_select 'form[data-training-duration-confirmation-message-value]', count: 1 do |forms|
        assert_includes forms.sole['data-training-duration-confirmation-message-value'], '¿Confirma __HOURS__ horas?'
      end
    end

    test 'a rejected Spanish report localizes the field name and preserves the editable report' do
      trainer = create(:trainer, locale: 'es')
      application = create(:application, :approved, :with_all_proofs, assigned_trainer: trainer)
      session = create(:training_session, :scheduled, trainer: trainer, application: application)
      product = create(:product)
      sign_in_for_integration_test(trainer)

      post complete_trainers_training_session_path(session), params: {
        completed_at: 1.day.from_now.strftime('%Y-%m-%dT%H:%M'), product_trained_on_id: product.id,
        duration_hours: '1', constituent_summary: 'Practicamos los subtítulos.', summary_locale: 'es'
      }

      assert_response :unprocessable_content
      assert_includes response.body, 'Fecha y hora reales de finalización no puede estar en el futuro'
      assert_not_includes response.body, 'Completed at'
      assert_select 'textarea#complete_constituent_summary', text: 'Practicamos los subtítulos.'
    end

    test 'an unsupported stored trainer locale falls back to the default without a rendering error' do
      trainer = create(:trainer, locale: 'unsupported')
      application = create(:application, :approved, :with_all_proofs, assigned_trainer: trainer)
      session = create(:training_session, :scheduled, trainer: trainer, application: application)
      sign_in_for_integration_test(trainer)

      get trainers_training_session_path(session, locale: 'unsupported')

      assert_response :success
      assert_select 'h1', text: "Training Session ##{session.appointment_number} Details"
      assert_select 'label[for=complete_constituent_summary]', text: /Shared session summary/
    end

    test 'the completed session list uses the actual Spanish viewer locale for headings statuses and durations' do
      trainer = create(:trainer, locale: 'es')
      application = create(:application, :approved, :with_all_proofs, assigned_trainer: trainer)
      session = create(:training_session, :completed, trainer: trainer, application: application, duration_hours: '2.5')
      sign_in_for_integration_test(trainer)

      get completed_trainers_training_sessions_path

      assert_response :success
      assert_select 'h1', text: /Sesiones de capacitación completadas/
      assert_match(/2[.,]5 horas/, response.body)
      assert_includes response.body, I18n.t('trainer_workflow.statuses.completed', locale: :es)
      assert_select "a[href='#{trainers_training_session_path(session)}'][aria-label]" do |links|
        assert_includes links.sole['aria-label'], session.application.user.full_name
        assert_includes links.sole['aria-label'], session.appointment_number.to_s
      end
      assert_select '.translation_missing', count: 0
    end

    test 'a completed trainer report labels stored summary language and duration in the viewer locale' do
      trainer = create(:trainer, locale: 'es')
      application = create(:application, :approved, :with_all_proofs, assigned_trainer: trainer)
      session = create(:training_session, :completed, trainer: trainer, application: application, duration_hours: 1, summary_locale: 'en')
      sign_in_for_integration_test(trainer)

      get trainers_training_session_path(session)

      assert_response :success
      assert_select 'dt', text: 'Resumen compartido con la persona — inglés'
      assert_select 'dd', text: '1 hora'
      assert_select 'h2', text: 'Recursos del producto usado en la capacitación'
      assert_includes response.body, session.constituent_summary
    end
  end
end
