# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class ProductLifecycleTest < ApplicationSystemTestCase
    test 'admin creates edits publishes guidance and archives a product without losing constituent history' do
      admin = create(:admin)
      system_test_sign_in(admin, bypass_mfa_enrollment: true)
      visit admin_products_path
      click_link 'Add product'
      assert_selector 'h1', count: 1, text: 'New Product'
      assert_link 'Back to Dashboard', href: admin_dashboard_path
      assert_link 'Back to Products', href: admin_products_path
      assert_link 'Cancel', href: admin_products_path
      find_link('Back to Dashboard', exact: true).execute_script('this.focus()')
      page.driver.browser.keyboard.type(:Tab)
      assert_selector "a[href='#{admin_products_path}']:focus", text: 'Back to Products'
      select 'Devices', from: 'Category'
      check 'I have verified the manufacturer and exact model'
      check 'Deaf'
      fill_in 'Manufacturer', with: 'Journey Devices'
      fill_in 'Name', with: 'Resource Journey Tablet'
      fill_in 'Model number', with: 'JOURNEY-001'
      fill_in 'MSRP (USD)', with: '1299.00'
      find('input[name="product[device_types][]"][value="Tablet"]').check
      fill_in 'Description', with: 'A tablet awaiting public guidance.'
      fill_in 'Features', with: 'Tactile buttons and a large display.'
      fill_in 'Compatibility notes', with: 'Works with Bluetooth keyboards.'
      fill_in 'Documentation URL', with: 'ftp://example.org/tablet-docs'
      assert_no_horizontal_overflow
      take_screenshot('product-catalog-classification-and-msrp', html: true, full: true)
      assert_no_difference('Product.count') do
        click_button 'Save Product'
        assert_selector '[role=alert]', text: /Documentation url/
      end
      assert_field 'Manufacturer', with: 'Journey Devices'
      assert_field 'Name', with: 'Resource Journey Tablet'
      assert_field 'Model number', with: 'JOURNEY-001'
      assert_equal BigDecimal('1299.00'), find_field('MSRP (USD)').value.to_d
      assert_field 'Category', with: 'devices'
      assert_checked_field 'I have verified the manufacturer and exact model'
      assert_checked_field 'Tablet'
      assert_checked_field 'Deaf', exact: true
      assert_field 'Description', with: 'A tablet awaiting public guidance.'
      assert_field 'Features', with: 'Tactile buttons and a large display.'
      assert_field 'Compatibility notes', with: 'Works with Bluetooth keyboards.'
      assert_field 'Documentation URL', with: 'ftp://example.org/tablet-docs'
      assert_no_difference('Product.count') do
        click_button 'Save Product'
        assert_selector '[role=alert]', text: /Documentation url/
      end
      take_screenshot('product-entry-unchanged-validation-retry', html: true, full: true)
      page.current_window.resize_to(390, 844)
      assert_no_horizontal_overflow
      take_screenshot('product-entry-validation-retry-narrow', html: true, full: true)

      select 'Alerters, accessories, and equipment', from: 'Category'
      assert_checked_field 'Tablet'
      uncheck 'Tablet'
      check 'Accessory'
      select 'Devices', from: 'Category'
      assert_checked_field 'Accessory'
      uncheck 'Accessory'
      check 'Tablet'
      select 'Alerters, accessories, and equipment', from: 'Category'
      select 'Devices', from: 'Category'
      assert_selector '#product-type-accessory[disabled]', visible: :all
      assert_no_selector '#product-type-accessory'
      uncheck 'Deaf', exact: true
      check 'DeafBlind'
      fill_in 'Documentation URL', with: 'https://example.org/tablet-docs'
      assert_difference('Product.count', 1) do
        click_button 'Save Product'
        assert_current_path admin_products_path
        assert_text 'Product successfully created.'
      end
      product = Product.find_by!(model_number: 'JOURNEY-001')
      assert_equal ['Tablet'], product.device_types
      assert_equal ['deafblind'], product.eligible_disability_groups
      assert_equal 'devices', product.category
      assert product.model_confirmed?
      assert_equal 'Journey Devices', product.manufacturer
      assert_equal 'Resource Journey Tablet', product.name
      assert_equal 'A tablet awaiting public guidance.', product.description
      assert_equal 'Tactile buttons and a large display.', product.features
      assert_equal 'Works with Bluetooth keyboards.', product.compatibility_notes
      assert_equal 'https://example.org/tablet-docs', product.documentation_url
      assert_equal BigDecimal('1299.00'), product.msrp
      page.current_window.resize_to(1200, 900)
      filter_catalog_to('Tablet')
      within('tr', text: product.name) { click_link 'Edit' }
      assert_selector 'h1', count: 1, text: 'Edit Product'
      fill_in 'Manufacturer', with: 'Journey Devices Updated'
      fill_in 'Model number', with: 'JOURNEY-002'
      fill_in 'MSRP (USD)', with: ''
      fill_in 'Name', with: 'Updated Resource Journey Tablet'
      fill_in 'Description', with: 'An accessible tablet with public guidance.'
      fill_in 'Features', with: 'Updated tactile controls.'
      fill_in 'Compatibility notes', with: 'Supports updated Bluetooth keyboards.'
      fill_in 'Documentation URL', with: 'https://example.org/updated-tablet-docs'
      check 'Computer'
      uncheck 'DeafBlind'
      click_button 'Save Product'
      assert_selector '[role=alert]', text: /Eligible disability groups/
      assert_field 'Manufacturer', with: 'Journey Devices Updated'
      assert_field 'Model number', with: 'JOURNEY-002'
      assert_field 'MSRP (USD)', with: ''
      assert_field 'Name', with: 'Updated Resource Journey Tablet'
      assert_field 'Description', with: 'An accessible tablet with public guidance.'
      assert_field 'Features', with: 'Updated tactile controls.'
      assert_field 'Compatibility notes', with: 'Supports updated Bluetooth keyboards.'
      assert_field 'Documentation URL', with: 'https://example.org/updated-tablet-docs'
      assert_field 'Category', with: 'devices'
      assert_checked_field 'Tablet'
      assert_checked_field 'Computer'
      assert_checked_field 'I have verified the manufacturer and exact model'
      assert_unchecked_field 'DeafBlind'
      assert_equal 'JOURNEY-001', product.reload.model_number
      assert_equal BigDecimal('1299.00'), product.msrp
      take_screenshot('product-entry-edit-metadata-retry', html: true, full: true)
      check 'DeafBlind'
      check 'Mobility'
      click_button 'Save Product'
      assert_current_path admin_products_path
      assert_text 'Product successfully updated.'
      assert_equal 'Updated Resource Journey Tablet', product.reload.name
      assert_equal 'Journey Devices Updated', product.manufacturer
      assert_equal 'JOURNEY-002', product.model_number
      assert_nil product.msrp
      assert_equal 'devices', product.category
      assert product.model_confirmed?
      assert_equal %w[Tablet Computer].sort, product.device_types.sort
      assert_equal %w[deafblind mobility], product.eligible_disability_groups
      assert_equal 'An accessible tablet with public guidance.', product.description
      assert_equal 'Updated tactile controls.', product.features
      assert_equal 'Supports updated Bluetooth keyboards.', product.compatibility_notes
      assert_equal 'https://example.org/updated-tablet-docs', product.documentation_url
      filter_catalog_to('Tablet')
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
      filter_catalog_to('Tablet')
      within('tr', text: product.name) { click_button 'Discontinue product' }
      assert_text 'Product discontinued.'
      assert product.reload.archived?
      assert_no_selector 'tr', text: product.name, visible: :all

      system_test_switch_user(constituent)
      visit constituent_portal_products_path
      click_link "#{product.manufacturer} #{product.name}"
      assert_selector 'h1', text: product.name
      assert_no_horizontal_overflow
      take_screenshot('product-lifecycle-archived-device-history', html: true, full: true)
    ensure
      page.current_window.resize_to(1200, 800)
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
    test 'catalog groups accessories once and keeps search sort and disability filters through pagination' do
      Product.by_device_types(['Accessory']).find_each { |product| product.update!(eligible_disability_groups: ['speech']) }
      shared = create(:product, name: 'Shared tactile accessory', manufacturer: 'AAA Catalog', category: 'alerters_accessories_equipment',
                                model_number: 'CAT-000', device_types: %w[Accessory Signaler], eligible_disability_groups: %w[deafblind deaf])
      deaf = create(:product, name: 'Catalog Deaf-only accessory', category: 'alerters_accessories_equipment',
                              device_types: ['Accessory'], eligible_disability_groups: ['deaf'])
      mobility = create(:product, name: 'Catalog Mobility accessory', category: 'alerters_accessories_equipment',
                                  device_types: ['Accessory'], eligible_disability_groups: ['mobility'])
      products = Array.new(Pagy::DEFAULT[:limit]) do |index|
        create(:product, name: format('Catalog accessory %03d', index), manufacturer: index.even? ? 'ZZZ Catalog' : 'ZZ Catalog',
                         model_number: format('CAT-%03d', index + 1), category: 'alerters_accessories_equipment',
                         device_types: %w[Accessory Signaler], eligible_disability_groups: ['deafblind'])
      end
      archived = create(:product, :archived, name: 'Archived tactile accessory', manufacturer: 'ZZZZ Catalog', category: 'alerters_accessories_equipment',
                                             model_number: 'CAT-999', device_types: ['Accessory'], eligible_disability_groups: ['deafblind'])
      system_test_sign_in(create(:admin), bypass_mfa_enrollment: true)
      page.current_window.resize_to(1200, 900)
      visit admin_products_path
      check 'Accessory'
      check 'DeafBlind'
      check 'Include discontinued products'
      fill_in 'Search by manufacturer, model, or name', with: 'catalog'
      find_field('Search by manufacturer, model, or name').send_keys(:enter)
      assert_field 'Sort by', with: 'manufacturer'
      assert_selector "[data-disability-groups=deafblind] tbody tr:first-child#product_#{products[1].id}"
      select 'Model A–Z', from: 'Sort by'
      click_button 'Apply Filters'

      assert_selector '[data-catalog-category]', count: 1
      assert_selector '[data-catalog-category=alerters_accessories_equipment] > summary', text: "#{Pagy::DEFAULT[:limit]} products on this page"
      assert_selector '#products_list tbody tr', count: Pagy::DEFAULT[:limit]
      assert_selector "#product_#{shared.id}", count: 1
      assert_selector '[data-disability-groups="deaf deafblind"] h3', exact_text: 'Deaf, DeafBlind'
      assert_no_selector "#product_#{deaf.id}, #product_#{mobility.id}"
      assert_selector "[data-disability-groups=deafblind] tbody tr:first-child#product_#{products.first.id}"
      assert_no_horizontal_overflow
      take_screenshot('product-catalog-accessories-disability-groups', html: true, full: true)
      page.current_window.resize_to(390, 844)
      find_field('Search by manufacturer, model, or name').execute_script('this.focus()')
      page.driver.browser.keyboard.type(:Tab)
      assert_selector '#sort:focus'
      assert_no_horizontal_overflow
      take_screenshot('product-catalog-search-sort-narrow', html: true, full: true)
      page.current_window.resize_to(1200, 900)

      find('nav[aria-label=Products] a[rel=next]').click
      assert_checked_field 'Accessory'
      assert_checked_field 'DeafBlind'
      assert_checked_field 'Include discontinued products'
      assert_field 'Search by manufacturer, model, or name', with: 'catalog'
      assert_field 'Sort by', with: 'model'
      assert_selector '[data-catalog-category]', count: 1
      assert_selector '#products_list tbody tr', count: 2
      within("#product_#{archived.id}") { assert_text 'Discontinued' }
      assert_no_selector "#product_#{deaf.id}, #product_#{mobility.id}"
      take_screenshot('product-catalog-filtered-next-page', html: true, full: true)

      uncheck 'DeafBlind'
      check 'Mobility'
      click_button 'Apply Filters'
      assert_unchecked_field 'DeafBlind'
      assert_checked_field 'Mobility'
      assert_checked_field 'Accessory'
      assert_checked_field 'Include discontinued products'
      assert_field 'Search by manufacturer, model, or name', with: 'catalog'
      assert_field 'Sort by', with: 'model'
      assert_selector '#products_list tbody tr', count: 1
      assert_selector "#product_#{mobility.id}"
      assert_selector '[data-disability-groups=mobility] h3', exact_text: 'Mobility'
      assert_no_selector 'nav[aria-label=Products]'
      page.current_window.resize_to(390, 844)
      assert_no_horizontal_overflow
      take_screenshot('product-catalog-disability-filter-changed-narrow', html: true, full: true)
      click_link 'Clear filters'
      assert_field 'Search by manufacturer, model, or name', with: ''
      assert_field 'Sort by', with: 'manufacturer'
      assert_unchecked_field 'Accessory'
      assert_unchecked_field 'Mobility'
      assert_unchecked_field 'Include discontinued products'
    end

    teardown do
      @public_guide_pdf&.close!
    end

    private

    def filter_catalog_to(device_type)
      check device_type
      click_button 'Apply Filters'
      assert_checked_field device_type
      assert_selector 'details[open][data-catalog-category] tbody tr'
    end

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
