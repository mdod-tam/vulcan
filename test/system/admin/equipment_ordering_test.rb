# frozen_string_literal: true

require 'application_system_test_case'
require 'csv'

module Admin
  class EquipmentOrderingTest < ApplicationSystemTestCase
    test 'filtered model selection exports units and reuses a PO after an editable validation retry' do
      admin = create(:admin)
      vendor = create(:vendor)
      replacement_vendor = create(:vendor)
      phone = create(:product, name: 'Shared Order Phone', manufacturer: 'Accessible Maker', model_number: 'PHONE-17')
      phone.vendors << vendor
      first = create(:equipment_need, product: phone)
      second = create(:equipment_need, product: phone, remaining_quantity: 2)
      detached = create(:equipment_item, application: first.application, product: phone, purchase_order: nil, tracking_number: 'PRIVATE-PACKAGE')
      excluded = create(:equipment_need, application: first.application, product: create(:product, name: 'Excluded model'))
      existing = create(:purchase_order, vendor: vendor, number: 'SHARED-00042')
      context = { tab: 'needs_ordering', product_id: phone.id.to_s, vendor_id: vendor.id.to_s }
      system_test_sign_in(admin)
      visit admin_applications_path
      assert_selector "a[href='#{admin_equipment_index_path}']", text: 'Equipment'
      take_screenshot('equipment-ordering-applications-entry', html: true, full: true)
      click_link 'Equipment', match: :first
      select phone.name, from: 'Catalog Model'
      select vendor.business_name, from: 'Vendor'
      click_button 'Filter'
      assert_current_path admin_equipment_index_path, ignore_query: true
      assert_equal context, Rack::Utils.parse_nested_query(URI.parse(page.current_url).query).slice(*context.keys.map(&:to_s)).symbolize_keys
      assert_selector 'nav[aria-label="Equipment queues"] a[aria-current=page].bg-indigo-700', text: 'Needs Ordering'
      assert_text '4 units across 2 applications'
      assert_no_selector 'section[data-equipment-selection-target="group"]', text: excluded.product.name
      group = find('section[data-equipment-selection-target="group"]', text: phone.name)
      assert_selector :checkbox, "Select group: #{phone.manufacturer} / #{phone.name} / #{phone.model_number}"
      toggle_selection_by_keyboard(group.find('input[name="group_product_ids[]"]'))
      assert_selector 'input[name="need_ids[]"]:checked', count: 2
      assert_selector 'input[name="item_ids[]"]:checked', count: 1
      take_screenshot('equipment-ordering-selected-queue', html: true, full: true)

      csv = selected_bid_csv
      rows = CSV.parse(csv, headers: true)
      assert_equal 1, rows.size
      assert_equal '4', rows.sole['Required quantity']
      assert_equal 'PHONE-17', rows.sole['Model identifier']
      assert_not_includes csv, 'PRIVATE-PACKAGE'
      assert_not_includes csv, excluded.product.name
      assert_not_includes csv, first.application.user.email
      toggle_selection_by_keyboard(group.find("input[name='need_ids[]'][value='#{second.id}']"))
      assert_no_selector 'input[name="group_product_ids[]"]:checked'
      assert_equal '2', CSV.parse(selected_bid_csv, headers: true).sole['Required quantity']
      toggle_selection_by_keyboard(group.find('input[name="group_product_ids[]"]'))
      click_button 'Record Winning Bid & PO'
      assert_text '4 physical units across 2 applications'
      assert_text 'Previously ordered devices to relink'
      assert_text "Device ##{detached.id}"
      take_screenshot('equipment-ordering-review', html: true, full: true)

      fill_in "quantity_#{second.id}", with: 1
      select vendor.business_name, from: 'Vendor'
      fill_in 'PO number', with: '00042-RETRY'
      fill_in 'Date PO sent', with: '13/45/2026'
      submit_purchase_order_by_keyboard
      2.times do |attempt|
        assert_selector '[role="alert"]', text: /Date PO sent/
        assert_selector '#purchase-order-errors:focus'
        assert_field "quantity_#{second.id}", with: '1'
        assert_selector :select, 'Vendor', selected: vendor.business_name
        assert_field 'PO number', with: '00042-RETRY'
        assert_field 'Date PO sent', with: '13/45/2026'
        assert_selector '#purchase_order_sent_at[aria-invalid=true][aria-describedby="purchase_order_sent_at-help purchase_order_sent_at-error"]'
        assert_selector "input[name='purchase_order[items][][id]'][value='#{detached.id}']", visible: :all
        submit_purchase_order_by_keyboard if attempt.zero?
      end
      page.current_window.resize_to(390, 844)
      take_screenshot('equipment-ordering-invalid-retry-mobile', html: true, full: true)
      page.current_window.resize_to(1200, 800)
      fill_in "quantity_#{second.id}", with: 2
      fill_in "quantity_#{second.id}", with: 1
      select replacement_vendor.business_name, from: 'Vendor'
      fill_in 'PO number', with: 'CORRECTED-00043'
      fill_in 'Date PO sent', with: Date.current.strftime('%m/%d/%Y')
      find_by_id('purchase_order_legacy_mapping').check
      find_by_id('purchase_order_legacy_mapping').uncheck
      option = find("#purchase_order_existing option[value='#{existing.id}:#{existing.lock_version}']").text
      select option, from: 'Link to an existing PO (leave blank to create one)'
      select 'Create a new PO', from: 'Link to an existing PO (leave blank to create one)'
      assert_selector :select, 'Vendor', selected: replacement_vendor.business_name
      assert_field 'PO number', with: 'CORRECTED-00043'
      assert_field 'Date PO sent', with: Date.current.strftime('%m/%d/%Y')
      assert_field "quantity_#{second.id}", with: '1'
      select option, from: 'Link to an existing PO (leave blank to create one)'
      submit_purchase_order_by_keyboard

      assert_text 'Purchase order recorded.'
      assert_text 'SHARED-00042'
      assert_text 'Awaiting Shipment'
      assert_equal 1, PurchaseOrder.where(vendor: vendor).count
      assert_equal 3, existing.equipment_items.count
      assert_equal existing.id, detached.reload.purchase_order_id
      assert_equal 1, second.reload.remaining_quantity
      take_screenshot('equipment-ordering-po-detail', html: true, full: true)
      device = existing.equipment_items.find_by!(application: first.application)
      within "#equipment-item-#{device.id}" do
        click_link "##{first.application_id}"
      end
      assert_current_path admin_application_path(first.application_id), ignore_query: true
      assert_selector "#equipment-item-#{device.id}"
      assert_equal "equipment-item-#{device.id}", URI.parse(page.current_url).fragment
      within '#equipment' do
        click_link 'Back to Equipment'
      end
      assert_current_path admin_equipment_index_path(context)
      assert_text '1 new device still needed'
      assert_text '1 unit across 1 application'
      click_link 'Purchase Orders'
      assert_current_path admin_purchase_orders_path(return_context: context)
      assert_link "#{existing.vendor.business_name} · PO #{existing.number}", href: admin_purchase_order_path(existing, return_context: context)
      click_link 'Back to Equipment'
      assert_current_path admin_equipment_index_path(context)
      take_screenshot('equipment-ordering-back-context', html: true, full: true)
    ensure
      page.current_window.resize_to(1200, 800)
    end

    test 'stale PO and need versions refuse unchanged retries until staff reopen the current review' do
      admin = create(:admin)
      vendor = create(:vendor)
      need = create(:equipment_need)
      need.product.vendors << vendor
      order = create(:purchase_order, vendor: vendor, number: 'STALE-REVIEW')
      context = { tab: 'needs_ordering', product_id: need.product_id.to_s, vendor_id: vendor.id.to_s }
      system_test_sign_in(admin)
      visit new_admin_purchase_order_path(need_ids: [need.id], return_context: context)
      assert_text '1 physical unit across 1 application'
      fill_in "quantity_#{need.id}", with: 2
      assert_text '2 physical units across 1 application'
      fill_in "quantity_#{need.id}", with: 1
      assert_text '1 physical unit across 1 application'
      select_existing_order(order)
      submitted_order_version = order.lock_version
      Equipment::Correction.new(actor: admin).update_purchase_order!(
        purchase_order: order, attributes: { number: 'CURRENT-REVIEW' }, expected_version: order.lock_version,
        expected_item_versions: {}, reason: 'Another staff member corrected the PO reference.'
      )

      2.times do
        assert_no_difference(['EquipmentItem.count', 'PurchaseOrder.count', 'Event.count']) do
          submit_purchase_order_by_keyboard
          assert_selector '[role="alert"]', text: /Refresh and review/
        end
        assert_equal "#{order.id}:#{submitted_order_version}", find_field('Link to an existing PO (leave blank to create one)').value
      end
      take_screenshot('equipment-ordering-stale-po-retry', html: true, full: true)
      reopen_review(context)
      select_existing_order(order.reload)
      submitted_need_version = need.lock_version
      EquipmentNeeds::Writer.update!(
        need.application,
        rows: [need.attributes.slice('id', 'product_id', 'remaining_quantity', 'lock_version').merge('remaining_quantity' => 2)],
        expected_initialized_at: need.application.equipment_needs_initialized_at.iso8601(6), actor: admin, reason: 'Another staff member added one new unit.'
      )

      2.times do
        assert_no_difference(['EquipmentItem.count', 'PurchaseOrder.count', 'Event.count']) do
          submit_purchase_order_by_keyboard
          assert_selector '[role="alert"]', text: /Refresh and review/
        end
        assert_selector "input[name='purchase_order[needs][][lock_version]'][value='#{submitted_need_version}']", visible: :all
      end
      take_screenshot('equipment-ordering-stale-need-retry', html: true, full: true)
      reopen_review(context)
      assert_selector "input[name='purchase_order[needs][][lock_version]'][value='#{need.reload.lock_version}']", visible: :all
      select_existing_order(order.reload)
      fill_in "quantity_#{need.id}", with: 1
      submit_purchase_order_by_keyboard
      assert_text 'Purchase order recorded.'
      assert_equal order.id, need.application.equipment_items.sole.purchase_order_id
      assert_equal 1, need.reload.remaining_quantity
      take_screenshot('equipment-ordering-stale-refreshed-save', html: true, full: true)
    end

    test 'narrow queue wraps long identifiers and keeps filters within the viewport' do
      product = create(:product, name: "Equipment #{'M' * 100}", manufacturer: 'Supported Manufacturer', model_number: "MODEL-#{'N' * 80}")
      vendor = create(:vendor, business_name: "Vendor #{'V' * 100}")
      order = create(:purchase_order, vendor: vendor, number: "PO#{'P' * 98}")
      tracking_number = "1Z#{'9' * 126}"
      create(:equipment_item, product: product, purchase_order: order, shipped_at: Date.current, tracking_number: tracking_number, carrier: 'ups')
      system_test_sign_in(create(:admin))
      page.current_window.resize_to(390, 844)
      visit admin_equipment_index_path(tab: 'shipped', product_id: product.id, vendor_id: vendor.id)
      assert_text product.name
      assert_text product.model_number
      assert_text order.number
      assert_text tracking_number
      assert_select 'Catalog Model', selected: "#{product.manufacturer} / #{product.name} / #{product.model_number}"
      assert_select 'Vendor', selected: vendor.business_name
      take_screenshot('equipment-queue-long-identifiers-mobile', html: true, full: true)
      geometry = page.evaluate_script(<<~JS)
        (() => {
          const bounds = element => { const rect = element.getBoundingClientRect(); return [rect.left, rect.right]; };
          const textLines = Array.from(document.querySelectorAll('section h2, section li a, section li span')).flatMap(element => {
            const range = document.createRange();
            range.selectNodeContents(element);
            return Array.from(range.getClientRects()).map(rect => [rect.left, rect.right]);
          });
          return { viewport: window.innerWidth, pageWidth: document.documentElement.scrollWidth, textLines,
            filters: Array.from(document.querySelectorAll('#product_id, #vendor_id')).map(bounds) };
        })()
      JS
      assert_operator geometry['pageWidth'], :<=, geometry['viewport']
      assert geometry['textLines'].all? { |left, right| left >= 0 && right <= geometry['viewport'] }, 'Queue identifiers must wrap within the viewport'
      assert geometry['filters'].all? { |left, right| left >= 0 && right <= geometry['viewport'] }, 'Queue filters must fit within the viewport'
    ensure
      page.current_window.resize_to(1200, 800)
    end

    test 'staff confirm an empty legacy purchasing list and retain readonly history after archival' do
      FeatureFlag.disable!(:vouchers_enabled)
      admin = create(:admin)
      vendor = create(:vendor)
      product = create(:product, name: 'Current catalog need')
      product.vendors << vendor
      create(:equipment_need, product: product)
      application = create(:application, :approved, :with_all_proofs, equipment_bids_sent_at: Date.new(2026, 9, 9),
                                                                      equipment_po_sent_at: Date.new(2026, 9, 10),
                                                                      equipment_tracking_number: 'EARLIER-PACKAGE')
      report = build(:evaluation, :completed, application: application, recommendation_outcome: :outside_catalog,
                                              recommendation_notes: 'The earlier order needs staff review')
      report.recommended_products = []
      report.products_tried = []
      report.save!
      assert_not EquipmentNeeds::Writer.initialize_from!(report, actor: admin)
      original_report = report.reload.attributes
      context = { tab: 'needs_ordering', product_id: product.id.to_s, vendor_id: vendor.id.to_s }
      system_test_sign_in(admin)
      visit admin_equipment_index_path(context)
      within '#equipment-legacy-review' do
        assert_link "Application ##{application.id}", href: admin_application_path(application, anchor: 'equipment', return_context: context)
      end
      page.current_window.resize_to(390, 844)
      assert_operator page.evaluate_script('document.documentElement.scrollWidth'), :<=, 390
      take_screenshot('equipment-legacy-pending-review-mobile', html: true, full: true)
      within '#equipment-legacy-review' do
        click_link "Application ##{application.id}"
      end
      assert_current_path admin_application_path(application, return_context: context)
      assert_equal 'equipment', URI.parse(page.current_url).fragment
      within '#equipment' do
        assert_text 'Earlier fulfillment needs review'
        assert_text 'September 09, 2026'
        assert_text 'September 10, 2026'
        assert_text 'EARLIER-PACKAGE'
        assert_no_text 'No equipment needed'
      end
      page.current_window.resize_to(1200, 800)
      take_screenshot('equipment-legacy-pending-application', html: true, full: true)
      within '#equipment' do
        click_link 'Edit equipment needs'
      end
      fill_in 'Reason for adjustment', with: 'Reviewed the earlier order; no new catalog device is needed.'
      assert_difference -> { application.events.where(action: 'equipment_needs_updated').count }, 1 do
        click_button 'Save purchasing needs'
        assert_text 'Purchasing needs updated.'
      end
      assert_current_path admin_equipment_index_path(context)
      assert_no_selector '#equipment-legacy-review a', text: "Application ##{application.id}"
      assert application.reload.equipment_needs_initialized_at
      assert application.equipment_legacy_unmapped?
      visit admin_application_path(application, anchor: 'equipment', return_context: context)
      within '#equipment' do
        assert_text 'No equipment needed'
        assert_no_text 'Earlier fulfillment needs review'
        assert_text 'September 10, 2026'
        assert_text 'EARLIER-PACKAGE'
      end
      take_screenshot('equipment-legacy-confirmed-empty-application', html: true, full: true)
      application.transition_status!(:archived, actor: admin)
      visit admin_equipment_index_path(context)
      assert_no_selector '#equipment-legacy-review a', text: "Application ##{application.id}"
      visit admin_application_path(application, anchor: 'equipment', return_context: context)
      within '#equipment' do
        assert_text report.recommendation_notes
        assert_text 'September 09, 2026'
        assert_text 'September 10, 2026'
        assert_text 'EARLIER-PACKAGE'
        assert_no_link 'Edit equipment needs'
        assert_no_selector 'form'
      end
      take_screenshot('equipment-legacy-archived-history', html: true, full: true)
      assert_equal original_report, report.reload.attributes
      assert_empty application.equipment_items
      assert_empty application.equipment_needs
    ensure
      page.current_window.resize_to(1200, 800)
    end

    private

    def reopen_review(context)
      click_link 'Back to Equipment'
      assert_current_path admin_equipment_index_path(context)
      find('input[name="group_product_ids[]"]').check
      click_button 'Record Winning Bid & PO'
      assert_selector 'h1', text: 'Record Winning Bid & PO'
    end

    def select_existing_order(order)
      option = find("#purchase_order_existing option[value='#{order.id}:#{order.lock_version}']").text
      select option, from: 'Link to an existing PO (leave blank to create one)'
    end

    def toggle_selection_by_keyboard(control)
      control.execute_script('this.focus()')
      assert_equal control['value'], page.evaluate_script('document.activeElement.value')
      page.driver.browser.keyboard.type(' ')
    end

    def submit_purchase_order_by_keyboard
      find_button('Record purchase order').execute_script('this.focus()')
      assert_selector "input[type='submit'][value='Record purchase order']:focus"
      page.driver.browser.keyboard.type(:enter)
    end

    def selected_bid_csv
      page.evaluate_async_script(<<~JS)
        const done = arguments[0];
        const form = document.querySelector('form[data-controller="equipment-selection"]');
        const button = Array.from(form.querySelectorAll('button')).find(button => button.textContent === 'Export for bids');
        const url = new URL(button.formAction);
        new FormData(form).forEach((value, key) => url.searchParams.append(key, value));
        fetch(url, { credentials: 'same-origin' }).then(response => response.text()).then(done);
      JS
    end
  end
end
