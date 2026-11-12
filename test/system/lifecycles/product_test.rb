# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class ProductLifecycleTest < ApplicationSystemTestCase
    test 'admin creates edits publishes guidance and archives a product without losing constituent history' do
      admin = create(:admin)
      system_test_sign_in(admin, bypass_mfa_enrollment: true)
      visit admin_products_path
      click_link 'Add New Product'
      fill_in 'Manufacturer', with: 'Journey Devices'
      fill_in 'Name', with: 'Resource Journey Tablet'
      fill_in 'Model number', with: 'JOURNEY-001'
      find('input[name="product[device_types][]"][value="Tablet"]').check
      fill_in 'Description', with: 'A tablet awaiting public guidance.'
      assert_difference('Product.count', 1) do
        click_button 'Save Product'
        assert_current_path admin_products_path
        assert_text 'Product successfully created.'
      end
      product = Product.find_by!(model_number: 'JOURNEY-001')
      assert_equal ['Tablet'], product.device_types
      find('summary', text: 'Tablet').click
      within('tr', text: product.name) { click_link 'Edit' }
      fill_in 'Name', with: 'Updated Resource Journey Tablet'
      fill_in 'Description', with: 'An accessible tablet with public guidance.'
      click_button 'Save Product'
      assert_current_path admin_products_path
      assert_text 'Product successfully updated.'
      assert_equal 'Updated Resource Journey Tablet', product.reload.name
      assert_equal 'An accessible tablet with public guidance.', product.description
      find('summary', text: 'Tablet').click
      within('tr', text: product.name) { click_link 'Resources' }
      assert_selector 'h2', text: 'Public product resources'
      click_link 'Add resource'
      fill_in 'Descriptive title (in the resource language)', with: 'Guía de inicio'
      select 'Spanish', from: 'Content language'
      fill_in 'External URL', with: 'ftp://example.org/guide'
      click_button 'Save public resource'
      assert_selector '#save-resource-errors:focus'
      assert_field 'Descriptive title (in the resource language)', with: 'Guía de inicio'
      assert_field 'Content language', with: 'es'
      assert_field 'External URL', with: 'ftp://example.org/guide'
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

      click_link 'Edit resource'
      select 'PDF document', from: 'Resource source'
      fill_in 'Descriptive title (in the resource language)', with: '  '
      attach_file 'PDF document', public_guide_pdf.path
      clear_resource_upload!(admin)
      click_button 'Save public resource'
      assert_selector '#save-resource-errors:focus'
      assert_text File.basename(public_guide_pdf.path)
      assert_field 'Resource source', with: 'pdf'
      assert_field 'External URL', with: 'https://example.org/spanish-guide'
      assert_selector 'input[type="hidden"][name="product_resource[document]"]', visible: :all
      take_screenshot('product-resources-admin-pdf-retry', html: true, full: true)
      accepted_pdf_blob_id = ActiveStorage::Blob.find_signed!(find('input[type="hidden"][name="product_resource[document]"]', visible: :all).value).id
      fill_in 'Descriptive title (in the resource language)', with: '  '
      click_button 'Save public resource'
      assert_selector '#save-resource-errors:focus'
      assert_equal accepted_pdf_blob_id, ActiveStorage::Blob.find_signed!(find('input[type="hidden"][name="product_resource[document]"]', visible: :all).value).id
      click_button I18n.t('documents.upload.remove')
      assert_no_selector 'input[type="hidden"][name="product_resource[document]"]', visible: :all
      attach_file 'PDF document', public_guide_pdf.path
      clear_resource_upload!(admin)
      fill_in 'Descriptive title (in the resource language)', with: 'Guía PDF accesible'
      click_button 'Save public resource'
      assert_current_path admin_product_path(product)
      assert_text 'Guía PDF accesible'
      assert product.product_resources.sole.document.attached?
      assert_nil product.product_resources.sole.url

      constituent = create(:constituent, locale: 'es')
      application = create(:application, :approved, :with_all_proofs, user: constituent)
      purchase = create(:voucher_transaction, voucher: create(:voucher, application: application))
      purchase.voucher_transaction_products.create!(product: product, quantity: 1)
      system_test_switch_user(constituent)
      page.current_window.resize_to(390, 844)
      visit constituent_portal_products_path
      click_link "#{product.manufacturer} #{product.name}"
      assert_link 'Guía PDF accesible'
      assert_selector 'a[href*="/rails/active_storage/blobs/proxy/"]'
      assert_no_text 'No hay guías en español'
      assert_no_horizontal_overflow
      take_screenshot('product-resources-newly-published-pdf-narrow', html: true, full: true)

      system_test_switch_user(admin, bypass_mfa_enrollment: true)
      page.current_window.resize_to(1200, 900)
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
      fill_in 'External URL', with: 'https://example.org/replacement-guide'
      click_button 'Save public resource'
      assert_current_path admin_product_path(product)
      assert_link 'Guía PDF accesible', href: 'https://example.org/replacement-guide'
      assert_equal 'https://example.org/replacement-guide', resource.reload.url
      assert_not resource.document.attached?
      accept_confirm { click_button 'Delete resource' }
      assert_text 'Resource deleted.'
      assert_text 'No product guides have been added yet.'
      assert_empty product.product_resources
      click_link 'Back to products'
      find('summary', text: 'Tablet').click
      within('tr', text: product.name) { click_button 'Archive' }
      assert_text 'Product archived.'
      assert product.reload.archived?
      assert_no_selector 'tr', text: product.name, visible: :all

      system_test_switch_user(constituent)
      visit constituent_portal_products_path
      click_link "#{product.manufacturer} #{product.name}"
      assert_selector 'h1', text: product.name
      assert_no_horizontal_overflow
      take_screenshot('product-lifecycle-archived-device-history', html: true, full: true)
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

    def clear_resource_upload!(admin)
      assert_selector '[data-scan-state="pending"]'
      scan = DocumentScan.where(user: admin, purpose: 'product_resource').order(:id).last
      scan.update!(status: :clean, completed_at: Time.current)
      assert_selector '[data-scan-state="clean"]'
    end

    def public_guide_pdf
      @public_guide_pdf ||= Tempfile.new(['public-product-guide', '.pdf']).tap do |file|
        file.binmode
        file.write(Rails.root.join('test/fixtures/files/disability_certification_valid.pdf').binread)
        file.flush
      end
    end
  end
end
