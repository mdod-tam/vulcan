# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class EquipmentNeedsTest < ApplicationSystemTestCase
    test 'staff replace a model through validation retry and keep an intentional empty list' do
      FeatureFlag.disable!(:vouchers_enabled)
      admin = create(:admin)
      application = create(:application, :approved, :with_all_proofs)
      report = create(:evaluation, :completed, :with_single_product, application: application)
      original_product = report.recommended_products.first
      replacement = create(:product, name: 'Replacement consultation device')
      alternate = create(:product, name: 'Alternative consultation device')
      EquipmentNeeds::Writer.initialize_from!(report, actor: admin)
      original_report = report.reload.attributes
      system_test_sign_in(admin)
      visit admin_equipment_index_path(tab: 'needs_ordering', product_id: original_product.id)
      assert_text original_product.name
      take_screenshot('equipment-needs-original-queue', html: true, full: true)
      click_link 'Edit equipment needs', match: :first
      assert_text 'Original assessment recommendation'
      assert_selector 'main', count: 1
      assert_no_selector 'main main'
      assert_selector 'h2#original-recommendation-title'
      assert_text original_product.name
      fill_in 'equipment-need-quantity-0', with: 0
      replacement_label = page.find('select option', text: replacement.name).text
      select replacement_label, from: 'Catalog model'
      fill_in 'equipment-need-quantity-1', with: 2
      fill_in 'Reason for adjustment', with: 'The family needs the replacement model.'
      page.execute_script("document.querySelector('input[name=\"equipment_needs[rows][][remaining_quantity]\"]').value = '-1'")
      page.execute_script("document.querySelector('form[action$=\"/equipment_needs\"]').noValidate = true")
      click_button 'Save purchasing needs'

      assert_selector '[role="alert"]', text: /greater than or equal to 0/
      assert_selector '#equipment-needs-errors:focus'
      assert_field 'equipment-need-quantity-0', with: '-1'
      assert_field 'equipment-need-quantity-1', with: '2'
      assert_selector :select, 'Catalog model', selected: replacement_label
      assert_field 'Reason for adjustment', with: 'The family needs the replacement model.'
      assert_no_difference('Event.count') do
        page.execute_script("document.querySelector('form[action$=\"/equipment_needs\"]').noValidate = true")
        click_button 'Save purchasing needs'
        assert_selector '[role="alert"]', text: /greater than or equal to 0/
        assert_selector '#equipment-needs-errors:focus'
      end
      take_screenshot('equipment-needs-invalid-retry', html: true, full: true)
      fill_in 'equipment-need-quantity-0', with: 0
      alternate_label = page.find('select option', text: alternate.name).text
      select alternate_label, from: 'Catalog model'
      assert_selector :select, 'Catalog model', selected: alternate_label
      select 'Choose a model to add', from: 'Catalog model'
      assert_field 'Catalog model', with: ''
      select replacement_label, from: 'Catalog model'
      fill_in 'equipment-need-quantity-1', with: 3
      fill_in 'equipment-need-quantity-1', with: 2
      fill_in 'Reason for adjustment', with: 'Corrected purchasing decision for the replacement model.'
      assert_selector :select, 'Catalog model', selected: replacement_label
      assert_field 'equipment-need-quantity-1', with: '2'
      take_screenshot('equipment-needs-corrected-retry', html: true, full: true)
      click_button 'Save purchasing needs'

      assert_text 'Purchasing needs updated.'
      assert_current_path admin_equipment_index_path(tab: 'needs_ordering', product_id: original_product.id)
      assert_text 'No matching equipment exists.'
      visit admin_equipment_index_path(tab: 'needs_ordering', product_id: replacement.id)
      assert_text replacement.name
      assert_text '2 new devices still needed'
      take_screenshot('equipment-needs-replacement-queue', html: true, full: true)
      assert_equal original_report, report.reload.attributes
      assert_equal [original_product.id], report.recommended_product_ids
      assert_equal 0, EquipmentItem.where(application: application).count
      assert_not application.equipment_needs.exists?(product: alternate)
      assert_equal 'Corrected purchasing decision for the replacement model.',
                   application.events.find_by!(action: 'equipment_needs_updated').metadata['reason']

      click_link 'Edit equipment needs', match: :first
      fill_in 'equipment-need-quantity-1', with: 0
      fill_in 'Reason for adjustment', with: 'The family no longer needs a new device.'
      click_button 'Save purchasing needs'
      assert_text 'No matching equipment exists.'
      visit admin_application_path(application, anchor: 'equipment')
      within '#equipment' do
        assert_text 'No new devices are currently needed.'
        assert_text original_product.name
      end
      page.refresh
      assert_text 'No new devices are currently needed.'
      assert_empty application.equipment_needs.remaining
      take_screenshot('equipment-needs-empty-application', html: true, full: true)
    end

    test 'stale marker and row versions require explicit refresh before a corrected save' do
      FeatureFlag.disable!(:vouchers_enabled)
      admin = create(:admin)
      other_admin = create(:admin)
      application = create(:application, :approved, :with_all_proofs)
      product = create(:product, name: 'Device from another staff decision')
      system_test_sign_in(admin)
      visit edit_admin_application_equipment_needs_path(application)
      product_label = page.find('select option', text: product.name).text
      select product_label, from: 'Catalog model'
      fill_in 'equipment-need-quantity-0', with: 2
      fill_in 'Reason for adjustment', with: 'First tab purchasing decision.'

      EquipmentNeeds::Writer.update!(application, rows: [{ product_id: product.id, remaining_quantity: 3 }],
                                                  expected_initialized_at: '', actor: other_admin, reason: 'Other tab initialized the needs list.')
      successful_edits = application.events.where(action: 'equipment_needs_updated').count
      2.times do
        click_button 'Save purchasing needs'
        assert_selector '[role="alert"]', text: 'Purchasing needs changed. Refresh the page before saving.'
        assert_field 'Catalog model', with: product.id.to_s
        assert_field 'equipment-need-quantity-0', with: '2'
        assert_selector 'input[name="equipment_needs[expected_initialized_at]"][value=""]', visible: :all
      end
      assert_equal successful_edits, application.events.where(action: 'equipment_needs_updated').count
      assert_equal 3, application.equipment_needs.sole.remaining_quantity
      take_screenshot('equipment-needs-stale-marker-retry', html: true, full: true)

      click_link 'Review latest purchasing needs'
      assert_no_selector '[role="alert"]'
      assert_field 'equipment-need-quantity-0', with: '3'
      marker = application.reload.equipment_needs_initialized_at.iso8601(6)
      assert_selector "input[name='equipment_needs[expected_initialized_at]'][value='#{marker}']", visible: :all
      fill_in 'equipment-need-quantity-0', with: 4
      fill_in 'Reason for adjustment', with: 'First tab quantity correction.'

      need = application.equipment_needs.sole
      rows = [need.attributes.slice('id', 'product_id', 'remaining_quantity', 'lock_version').merge('remaining_quantity' => 5)]
      EquipmentNeeds::Writer.update!(application, rows: rows, expected_initialized_at: marker,
                                                  actor: other_admin, reason: 'Other tab changed the quantity.')
      successful_edits = application.events.where(action: 'equipment_needs_updated').count
      2.times do
        click_button 'Save purchasing needs'
        assert_selector '[role="alert"]', text: 'Equipment changed. Refresh and review your selection.'
        assert_field 'equipment-need-quantity-0', with: '4'
        assert_selector 'input[name="equipment_needs[rows][][lock_version]"][value="0"]', visible: :all
      end
      assert_equal successful_edits, application.events.where(action: 'equipment_needs_updated').count
      assert_equal 5, need.reload.remaining_quantity
      take_screenshot('equipment-needs-stale-version-retry', html: true, full: true)

      click_link 'Review latest purchasing needs'
      assert_no_selector '[role="alert"]'
      assert_field 'equipment-need-quantity-0', with: '5'
      assert_selector 'input[name="equipment_needs[rows][][lock_version]"][value="1"]', visible: :all
      fill_in 'equipment-need-quantity-0', with: 6
      fill_in 'Reason for adjustment', with: 'Reviewed the refreshed quantity before saving.'
      click_button 'Save purchasing needs'

      assert_text 'Purchasing needs updated.'
      assert_equal 6, need.reload.remaining_quantity
      assert_equal successful_edits + 1, application.events.where(action: 'equipment_needs_updated').count
      assert_empty application.equipment_items
      take_screenshot('equipment-needs-refreshed-save', html: true, full: true)
    end

    test 'staff confirm an outside catalog empty list once without changing the report or return context' do
      FeatureFlag.disable!(:vouchers_enabled)
      admin = create(:admin)
      vendor = create(:vendor)
      product = create(:product, name: 'Model for a later catalog decision')
      product.vendors << vendor
      application = create(:application, :approved, :with_all_proofs)
      report = build(:evaluation, :completed, application: application, recommendation_outcome: :outside_catalog,
                                              recommendation_notes: 'The specialist recommended a model outside the catalog.')
      report.recommended_products = []
      report.products_tried = []
      report.save!
      EquipmentNeeds::Writer.initialize_from!(report, actor: admin)
      original_report = report.reload.attributes
      marker = application.reload.equipment_needs_initialized_at
      context = { tab: 'needs_ordering', product_id: product.id.to_s, vendor_id: vendor.id.to_s }
      system_test_sign_in(admin)
      visit admin_application_path(application, anchor: 'equipment', return_context: context)
      within '#equipment' do
        assert_selector 'span.bg-amber-100.text-amber-800', text: 'Needs a catalog product'
        assert_selector '.sr-only', text: 'Fulfillment Status:', visible: :all
        assert_text report.recommendation_notes
        take_screenshot('equipment-needs-outside-catalog-pending', html: true, full: true)
        click_link 'Edit equipment needs'
      end

      assert_field 'Catalog model', with: ''
      reason = 'Reviewed the outside recommendation; no new catalog device is needed.'
      fill_in 'Reason for adjustment', with: reason
      edits = -> { application.events.where(action: 'equipment_needs_updated').count }
      assert_difference edits, 1 do
        click_button 'Save purchasing needs'
        assert_text 'Purchasing needs updated.'
      end
      assert_current_path admin_equipment_index_path(context)
      visit admin_application_path(application, anchor: 'equipment', return_context: context)
      within '#equipment' do
        assert_selector 'span.bg-gray-100.text-gray-800', text: 'No equipment needed'
        assert_selector '.sr-only', text: 'Fulfillment Status:', visible: :all
        assert_text 'No new devices are currently needed.'
        assert_no_text 'Needs a catalog product'
        assert_text report.recommendation_notes
        take_screenshot('equipment-needs-outside-catalog-confirmed-empty', html: true, full: true)
        click_link 'Edit equipment needs'
      end

      fill_in 'Reason for adjustment', with: reason
      assert_no_difference edits do
        click_button 'Save purchasing needs'
        assert_text 'Purchasing needs updated.'
      end
      assert_current_path admin_equipment_index_path(context)
      assert_equal 1, edits.call
      assert_equal reason, application.events.find_by!(action: 'equipment_needs_updated').metadata['reason']
      assert_equal marker, application.reload.equipment_needs_initialized_at
      assert_equal original_report, report.reload.attributes
      assert_empty report.recommended_product_ids
      assert_empty application.equipment_needs
      assert_empty application.equipment_items
    end
  end
end
