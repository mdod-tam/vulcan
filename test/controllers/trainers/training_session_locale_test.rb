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
      assert_select 'h2', text: '¿Qué ocurrió?'
      assert_select 'dt', text: 'Correo electrónico de contacto'
      assert_select 'p', text: 'Idioma preferido: inglés'
      assert_not_includes response.body, 'Translation missing'
      assert_not_includes response.body, '{:asl'
      assert_includes response.body, 'No proporcionado'
      assert_select 'label', text: 'Resumen compartido de la sesión'
      assert_select 'label', text: 'Lugar o instrucciones de la reunión (compartidos)'
      assert_select 'option', text: 'Reprogramar a petición de la persona'
      assert_select 'input[type=submit][value="Guardar informe completado"]'
      assert_select 'option', text: 'español'
      assert_select 'span', text: 'Programada'
      assert_select 'button', text: 'No'
      assert_select 'button', text: 'Sí'
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
      assert_includes response.body, 'Fecha de finalización real no puede estar en el futuro'
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
      assert_select 'label', text: 'Shared session summary'
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
