# frozen_string_literal: true

require 'application_system_test_case'

module ConstituentPortal
  class WorkflowLocaleTest < ApplicationSystemTestCase
    setup do
      @guardian = create(:constituent, locale: :es)
      system_test_sign_in(@guardian)
      page.current_window.resize_to(390, 844)
    end

    teardown do
      page.current_window.resize_to(1200, 800)
    end

    test 'Spanish dependent intake keeps labels help and controls usable at narrow width' do
      visit new_constituent_portal_dependent_path

      assert_selector 'h1', text: 'Agregar un dependiente nuevo'
      assert_field 'Nombre'
      assert_field 'Apellido'
      assert_text 'Usted recibirá las comunicaciones del programa para este dependiente.'
      assert_selectable_relationship
      assert_button 'Agregar dependiente'
      assert_no_selector '.translation_missing'
      take_screenshot('dependent-intake-mobile-es', full: true, html: true)

      uncheck 'Usar mi correo electrónico'
      fill_in 'Correo electrónico del dependiente', with: 'dependiente@example.com'
      assert_field 'Correo electrónico del dependiente', with: 'dependiente@example.com', disabled: false
      take_screenshot('dependent-contact-choice-mobile-es', full: true, html: true)
    end

    test 'Spanish proof upload includes translated guidance and expanded help at narrow width' do
      application = create(:application, :paper_rejected_proofs, user: @guardian)
      visit constituent_portal_application_new_proof_path(application, proof_type: :income)

      assert_selector 'h1', text: 'Subir nuevo comprobante de ingresos'
      assert_text 'Su comprobante de ingresos debe mostrar claramente su nombre'
      assert_button 'Enviar documento'
      find('summary', text: '¿Necesita ayuda para subir su documento?').click
      assert_text 'Seleccione el documento en su dispositivo.'
      assert_text 'Muestre toda la información requerida'
      assert_link ProgramContact.support_email
      assert_no_selector '.translation_missing'
      take_screenshot('proof-upload-help-mobile-es', full: true, html: true)
    end

    private

    def assert_selectable_relationship
      select 'Padre o madre', from: 'Su relación con el dependiente'
      assert_equal 'Parent', find('select[name="guardian_relationship[relationship_type]"]').value
    end
  end
end
