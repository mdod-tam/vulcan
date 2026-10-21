# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class ProductResourcesTest < ApplicationSystemTestCase
    test 'admin publishes edits and deletes exact product guidance with recoverable errors and PDF replacement' do
      admin = create(:admin)
      product = create(:product, name: 'Resource Journey Tablet')
      system_test_sign_in(admin)
      visit admin_products_path
      find('summary', text: 'Tablet').click
      within('tr', text: product.name) { click_link 'Resources' }
      assert_selector 'h2', text: 'Public product resources'
      take_screenshot('product-resources-admin-entry', html: true, full: true)
      click_link 'Add resource'
      fill_in 'Descriptive title (in the resource language)', with: 'Guía de inicio'
      select 'Spanish', from: 'Content language'
      fill_in 'External URL', with: 'ftp://example.org/guide'
      click_button 'Save public resource'
      assert_selector '#save-resource-errors:focus'
      assert_field 'Descriptive title (in the resource language)', with: 'Guía de inicio'
      assert_field 'Content language', with: 'es'
      assert_field 'External URL', with: 'ftp://example.org/guide'
      take_screenshot('product-resources-admin-url-retry', html: true, full: true)
      within('#save-resource-errors') { click_link href: '#product_resource_url' }
      assert_selector '#product_resource_url:focus'
      select 'English', from: 'Content language'
      assert_field 'Content language', with: 'en'
      select 'Spanish', from: 'Content language'
      assert_field 'Content language', with: 'es'
      click_button 'Save public resource'
      assert_selector '#save-resource-errors:focus'
      fill_in 'External URL', with: 'https://example.org/spanish-guide'
      click_button 'Save public resource'
      assert_current_path admin_product_path(product)
      assert_text 'Resource saved.'
      assert_link 'Guía de inicio', href: 'https://example.org/spanish-guide'
      take_screenshot('product-resources-admin-saved-link', html: true, full: true)

      click_link 'Edit resource'
      select 'PDF document', from: 'Resource source'
      fill_in 'Descriptive title (in the resource language)', with: '  '
      attach_file 'PDF document', public_guide_pdf.path
      click_button 'Save public resource'
      assert_selector '#save-resource-errors:focus'
      assert_text File.basename(public_guide_pdf.path)
      assert_field 'Resource source', with: 'pdf'
      assert_field 'External URL', with: 'https://example.org/spanish-guide'
      assert_selector 'input[name="product_resource[document_signed_id]"]', visible: :all
      take_screenshot('product-resources-admin-pdf-retry', html: true, full: true)
      accepted_pdf_reference = find('input[name="product_resource[document_signed_id]"]', visible: :all).value
      fill_in 'Descriptive title (in the resource language)', with: '  '
      click_button 'Save public resource'
      assert_selector '#save-resource-errors:focus'
      assert_equal accepted_pdf_reference, find('input[name="product_resource[document_signed_id]"]', visible: :all).value
      click_button I18n.t('documents.upload.remove')
      assert_no_selector 'input[name="product_resource[document_signed_id]"]', visible: :all
      attach_file 'PDF document', public_guide_pdf.path
      fill_in 'Descriptive title (in the resource language)', with: 'Guía PDF accesible'
      click_button 'Save public resource'
      assert_current_path admin_product_path(product)
      assert_text 'Guía PDF accesible'
      assert product.product_resources.sole.document.attached?
      assert_nil product.product_resources.sole.url
      take_screenshot('product-resources-admin-saved-pdf', html: true, full: true)

      constituent = create(:constituent, locale: 'es')
      application = create(:application, :approved, :with_all_proofs, user: constituent)
      purchase = create(:voucher_transaction, voucher: create(:voucher, application: application))
      purchase.voucher_transaction_products.create!(product: product, quantity: 1)
      switch_user(constituent)
      page.current_window.resize_to(390, 844)
      visit constituent_portal_products_path
      click_link "#{product.manufacturer} #{product.name}"
      assert_link 'Guía PDF accesible'
      assert_selector 'a[href*="/rails/active_storage/blobs/proxy/"]'
      assert_no_text 'No hay guías en español'
      assert_no_horizontal_overflow
      take_screenshot('product-resources-newly-published-pdf-narrow', html: true, full: true)

      switch_user(admin)
      visit admin_product_path(product)
      resource = product.product_resources.sole
      previous_pdf_blob_id = resource.document.blob_id
      click_link 'Edit resource'
      select 'External link', from: 'Resource source'
      fill_in 'External URL', with: ''
      click_button 'Save public resource'
      assert_selector '#save-resource-errors:focus'
      assert_field 'Resource source', with: 'url'
      assert_field 'External URL', with: ''
      assert_nil resource.reload.url
      assert resource.document.attached?
      assert_equal previous_pdf_blob_id, resource.document.blob_id
      take_screenshot('product-resources-admin-pdf-to-url-retry', html: true, full: true)
      fill_in 'External URL', with: 'https://example.org/replacement-guide'
      click_button 'Save public resource'
      assert_current_path admin_product_path(product)
      assert_link 'Guía PDF accesible', href: 'https://example.org/replacement-guide'
      assert_equal 'https://example.org/replacement-guide', resource.reload.url
      assert_not resource.document.attached?
      take_screenshot('product-resources-admin-pdf-to-url-saved', html: true, full: true)
      accept_confirm { click_button 'Delete resource' }
      assert_text 'Resource deleted.'
      assert_text 'No product guides have been added yet.'
      assert_empty product.product_resources
      take_screenshot('product-resources-admin-deleted', html: true, full: true)
    end

    test 'guardian device history and localized guides remain readable on a narrow screen' do
      guardian = create(:constituent, locale: 'es')
      dependent = create(:constituent)
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent)
      own = create(:application, :approved, :with_all_proofs, user: guardian)
      managed = create(:application, :approved, :with_all_proofs, user: dependent, managing_guardian: guardian)
      product = create(:product, :archived, name: 'Previously Supplied Tablet')
      shipment = create(:product, name: 'Dependent Shipment')
      purchase = create(:voucher_transaction, voucher: create(:voucher, application: own))
      purchase.voucher_transaction_products.create!(product: product, quantity: 1)
      create(:equipment_item, application: managed, product: shipment, shipped_at: Date.current, tracking_number: 'Sent')
      create(:product_resource, product: product, locale: 'en', title: 'English instructions')
      create(:product_resource, product: product, locale: 'es', title: 'Instrucciones en español')
      create(:product_resource, product: shipment, locale: 'en', title: 'Shipment guide in English')
      system_test_sign_in(guardian)
      page.driver.browser.resize(width: 390, height: 844)
      visit constituent_portal_products_path
      assert_text "Dispositivos de #{guardian.full_name}"
      assert_text "Dispositivos de #{dependent.full_name}"
      assert_text 'Comprado con vale'
      assert_text 'Enviado por el programa'
      assert_no_horizontal_overflow
      take_screenshot('devices-guardian-narrow', html: true, full: true)
      click_link "#{product.manufacturer} #{product.name}"
      assert_link 'Instrucciones en español'
      assert_text 'inglés · Otro idioma'
      assert_no_text 'No hay guías en español'
      assert_no_horizontal_overflow
      take_screenshot('product-resources-preferred-narrow', html: true, full: true)
      visit constituent_portal_product_path(shipment)
      assert_text 'No hay guías en español'
      assert_link 'Shipment guide in English'
      assert_no_horizontal_overflow
      take_screenshot('product-resources-alternative-narrow', html: true, full: true)
    end
    teardown do
      @public_guide_pdf&.close!
    end

    private

    def switch_user(user)
      system_test_sign_out
      install_stimulus_error_reporting
      system_test_sign_in(user)
      page.current_window.resize_to(1200, 900)
    end

    def assert_no_horizontal_overflow
      assert page.evaluate_script('document.documentElement.scrollWidth <= window.innerWidth'), 'Page overflows the viewport'
    end

    def public_guide_pdf
      @public_guide_pdf ||= Tempfile.new(['public-product-guide', '.pdf']).tap do |file|
        file.binmode
        file.write("%PDF-1.4\nPublic program product guidance. No personal or session information.\n")
        file.flush
      end
    end
  end
end
