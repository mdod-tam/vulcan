# frozen_string_literal: true

require 'test_helper'

module ConstituentPortal
  class ViewerLocaleTest < ActionDispatch::IntegrationTest
    setup do
      @guardian = create(:constituent, locale: :es)
      sign_in_for_integration_test(@guardian)
    end

    test 'application actions use the account locale without a locale parameter' do
      get new_constituent_portal_application_path
      assert_response :success
      assert_select 'html[lang="es"]'

      application = create(:application, :draft, user: @guardian)
      [constituent_portal_applications_path, constituent_portal_application_path(application),
       edit_constituent_portal_application_path(application)].each do |path|
        get path
        assert_response :success
        assert_select 'html[lang="es"]'
      end
      assert_equal :en, I18n.locale, 'request locale must be restored after the response'
    end

    test 'dependent intake translates controls while preserving stored relationship values' do
      get new_constituent_portal_dependent_path

      assert_response :success
      assert_select 'h1', text: 'Agregar un dependiente nuevo'
      assert_select 'label[for="dependent_first_name"]', text: 'Nombre'
      assert_select 'label[for="use_guardian_email_checkbox"]', text: /Usar mi correo electrónico/
      assert_select 'option[value="Parent"]', text: 'Padre o madre'
      assert_select 'input[type="submit"][value="Agregar dependiente"]'
      assert_select '.translation_missing', count: 0

      get new_constituent_portal_dependent_path(locale: :en)
      assert_response :success
      assert_select 'h1', text: 'Add New Dependent'
      assert_equal :en, I18n.locale
    end

    test 'dependent validation restores Spanish errors and submitted fields' do
      post constituent_portal_dependents_path,
           params: { dependent: { first_name: 'Lucía', last_name: 'Ejemplo', date_of_birth: '01/02/2015' },
                     guardian_relationship: { relationship_type: 'Parent' }, use_guardian_email: '1', use_guardian_phone: '1' }

      assert_response :unprocessable_content
      assert_select '#dependent_first_name[value="Lucía"]'
      assert_select '[role="alert"]', text: /Debe seleccionar al menos una discapacidad/
      assert_select 'input[type="submit"][value="Agregar dependiente"]'
      assert_select '.translation_missing', count: 0
    end

    test 'proof upload and refusal use the account locale for each supported proof type' do
      application = create(:application, :paper_rejected_proofs, user: @guardian, id_proof_status: :rejected)
      { income: 'ingresos', residency: 'residencia', id: 'identidad' }.each do |type, label|
        get constituent_portal_application_new_proof_path(application, proof_type: type)
        assert_response :success
        assert_select 'h1', text: "Subir nuevo comprobante de #{label}"
        assert_select 'input[type="submit"][value="Enviar documento"]'
        assert_select '.translation_missing', count: 0
      end

      post constituent_portal_application_proofs_resubmit_path(application), params: { proof_type: 'income' }
      assert_response :unprocessable_content
      assert_select 'h1', text: 'Subir nuevo comprobante de ingresos'
      assert_select '[role="alert"]', text: /Elija un archivo/
      assert_select 'input[type="submit"][value="Enviar documento"]'
    end

    test 'dependent edit uses structured disability errors in the selected language' do
      dependent = create(:constituent, hearing_disability: true)
      create(:guardian_relationship, guardian_user: @guardian, dependent_user: dependent, relationship_type: 'Parent')
      create(:application, user: dependent)

      patch constituent_portal_dependent_path(dependent),
            params: { dependent: Users::Constituent::DISABILITY_FLAGS.index_with(false) }

      assert_response :unprocessable_content
      assert_select 'fieldset[aria-invalid="true"] #disability-error', text: 'Debe seleccionar al menos una discapacidad.'
      assert_select 'input[type="submit"][value="Actualizar dependiente"]'
      assert_select '.translation_missing', count: 0
      assert_predicate dependent.reload, :hearing_disability?
    end

    test 'notification content chrome and read replacement share the selected request locale' do
      application = create(:application, user: @guardian)
      notice = create(:notification, recipient: @guardian, notifiable: application,
                                     action: 'proof_approved', metadata: { proof_type: 'income' })
      get notifications_path

      assert_response :success
      assert_select 'h1', text: 'Notificaciones'
      assert_select "#notification_#{notice.id}", text: /Comprobante de ingresos aprobado para/
      assert_select "#notification_#{notice.id} button", text: 'Marcar como leída'

      get notifications_path(locale: :en)
      assert_select 'h1', text: 'Notifications'
      assert_select "#notification_#{notice.id}", text: /Income proof approved for/
      assert_select "#notification_#{notice.id} button", text: 'Mark as read'

      action = css_select("#notification_#{notice.id} form").first['action']
      assert_equal mark_as_read_notification_path(notice, locale: :en), action
      post action, headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
      assert_response :success
      assert_select "#notification_#{notice.id}", text: /Income proof approved for/
      assert_not_nil notice.reload.read_at
      assert_equal :en, I18n.locale

      @guardian.update!(locale: :en)
      notice.update!(read_at: nil)
      get notifications_path(locale: :es)
      action = css_select("#notification_#{notice.id} form").first['action']
      assert_equal mark_as_read_notification_path(notice, locale: :es), action
      post action, headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
      assert_response :success
      assert_select "#notification_#{notice.id}", text: /Comprobante de ingresos aprobado para/
      assert_equal :en, I18n.locale
    end
  end
end
