# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class EquipmentOrderingTest < ApplicationSystemTestCase
    test 'local filtering retains hidden selections through mixed model bidding and explicit unsent PO reuse' do
      admin = create(:admin)
      phone = create(:product, name: 'Selected Phone')
      tablet = create(:product, name: 'Selected Tablet')
      need = create(:equipment_need, product: phone, remaining_quantity: 2)
      other = create(:equipment_need, product: tablet)
      existing = create(:purchase_order, number: 'SHARED-UNSENT-PO', sent_at: nil)
      system_test_sign_in(admin, bypass_mfa_enrollment: true)
      visit admin_equipment_index_path
      fill_in "quantity-#{need.id}", with: 2
      assert_selector "#equipment-row-EquipmentNeed-#{need.id}:checked"
      select equipment_label(tablet), from: 'Model'
      assert_selector '[role=status]', text: '1 selected (1 hidden by filters) · 2 units'
      click_button 'Select matching'
      assert_selector '[role=status]', text: '2 selected (1 hidden by filters) · 3 units'
      assert_selector "#equipment-row-EquipmentNeed-#{other.id}:checked"
      take_screenshot('equipment-native-filtered-selection', html: true, full: true)
      click_button 'Enter bid number'
      assert_selector 'h1', text: 'Enter bid number'
      assert_text phone.catalog_label
      assert_text tablet.catalog_label
      fill_in 'Bid number', with: 'MIXED-MODEL-BID'
      assert_no_difference 'EquipmentItem.count' do
        click_button 'Reserve selected products under this bid'
        assert_text 'Bid reserved.'
      end
      click_link 'Enter PO details for this bid'
      click_button 'Save PO details'
      assert_selector '[role=alert]', text: "PO number can't be blank"
      assert_field 'New PO number', with: ''
      assert_selector 'input[name^="line_versions["]', count: 2, visible: :all
      take_screenshot('equipment-award-validation-retry', html: true, full: true)
      find("select[name='purchase_order[existing]'] option[value='#{existing.id}:#{existing.lock_version}']").select_option
      assert_no_difference 'PurchaseOrder.count' do
        assert_difference 'EquipmentItem.count', 3 do
          click_button 'Save PO details'
          assert_text 'Award and unsent PO recorded.'
        end
      end
      assert_current_path admin_purchase_order_path(existing, return_context: { tab: 'needs_ordering', product_id: tablet.id.to_s })
      assert_equal 3, existing.equipment_items.count
      assert_nil existing.reload.sent_at
      assert_equal [0, 0], [need.reload.remaining_quantity, other.reload.remaining_quantity]
      assert_text 'PO sent date needed'
      take_screenshot('equipment-mixed-model-po-recorded', html: true, full: true)
    end

    test 'stale award contents reject unchanged retry until staff reopen current bid review' do
      admin = create(:admin)
      first = create(:equipment_need)
      second = create(:equipment_need)
      group = Equipment::Bidding.new(actor: admin).create!(number: 'AMENDED-BID', needs: [first, second].map { |need| selection(need) })
      system_test_sign_in(admin, bypass_mfa_enrollment: true)
      visit new_admin_purchase_order_path(bid_group_id: group.id)
      fill_in 'New PO number', with: 'STALE-CONTENTS-PO'
      released = group.active_lines.find_by!(equipment_need: first)
      Equipment::Bidding.new(actor: admin).release!(group: group, line_ids: [released.id], expected_version: group.lock_version, reason: 'Supplier did not quote this line')
      2.times do
        assert_no_difference ['PurchaseOrder.count', 'EquipmentItem.count'] do
          click_button 'Save PO details'
          assert_selector '[role=alert]', text: /Refresh/
        end
        assert_field 'New PO number', with: 'STALE-CONTENTS-PO'
      end
      take_screenshot('equipment-stale-bid-award-retry', html: true, full: true)
      visit new_admin_purchase_order_path(bid_group_id: group.id)
      assert_text 'This bid has changed. Review the products and quantities before awarding it.'
      fill_in 'New PO number', with: 'REVIEWED-CURRENT-CONTENTS'
      click_button 'Save PO details'
      assert_text 'Award and unsent PO recorded.'
      assert_equal 1, first.reload.remaining_quantity
      assert_equal 0, second.reload.remaining_quantity
      assert_equal 1, PurchaseOrder.find_by!(number: 'REVIEWED-CURRENT-CONTENTS').equipment_items.count
    end

    test 'admin application and assigned evaluator dashboard share the recorded shipment stage' do
      admin = create(:admin)
      evaluation = create(:evaluation, :completed, :with_single_product)
      EquipmentNeeds::Writer.initialize_from!(evaluation, actor: admin)
      need = evaluation.application.equipment_needs.sole
      group = Equipment::Bidding.new(actor: admin).create!(number: 'STAGE-BID', needs: [selection(need)])
      order = Equipment::Ordering.new(actor: admin).call(bid_group: group, application_versions: equipment_bid_profile_versions(group), expected_version: group.lock_version,
                                                         line_versions: group.active_lines.to_h { |line| [line.id.to_s, line.lock_version.to_s] },
                                                         purchase_order_attributes: { number: 'STAGE-PO' })
      system_test_sign_in(admin, bypass_mfa_enrollment: true)
      visit admin_application_path(evaluation.application)
      assert_text 'PO sent date needed'
      Equipment::Ordering.new(actor: admin).mark_sent!(order: order, sent_at: Date.current, expected_version: order.lock_version)
      page.refresh
      assert_text 'Shipping info needed'
      item = order.equipment_items.sole
      Equipment::Correction.new(actor: admin).update_item!(item: item, attributes: { shipped_at: Date.current, tracking_number: 'STAGE-TRACK' },
                                                           expected_version: item.lock_version, reason: 'Actual vendor shipment confirmed')
      page.refresh
      assert_text 'Shipment recorded'
      system_test_switch_user(evaluation.evaluator, bypass_mfa_enrollment: true)
      visit evaluators_dashboard_path
      within find_by_id('recent-completed-heading').find(:xpath, '../..') do
        assert_text evaluation.constituent.full_name
        assert_text 'Shipment recorded'
      end
      take_screenshot('equipment-shared-shipment-stage', html: true, full: true)
    end

    test 'narrow equipment queue wraps exact model labels and filter controls' do
      product = create(:product, name: "Model #{'M' * 100}", manufacturer: "Maker #{'A' * 80}")
      create(:equipment_need, product: product)
      system_test_sign_in(create(:admin), bypass_mfa_enrollment: true)
      page.current_window.resize_to(390, 844)
      visit admin_equipment_index_path
      assert_text product.catalog_label
      assert_operator page.evaluate_script('document.documentElement.scrollWidth'), :<=, 390
      take_screenshot('equipment-native-queue-narrow', html: true, full: true)
    ensure
      page.current_window.resize_to(1200, 800)
    end

    test 'archived applications retain submitted recommendations and physical device history' do
      admin = create(:admin)
      report = create(:evaluation, :completed, :with_single_product)
      product = report.recommended_products.sole
      item = create(:equipment_item, application: report.application, source_evaluation: report, product: product)
      report.application.transition_status!(:archived, actor: admin)
      system_test_sign_in(admin, bypass_mfa_enrollment: true)
      visit admin_application_path(report.application, anchor: 'equipment')
      assert_text product.catalog_label
      assert_selector "#equipment-item-#{item.id}"
      assert_no_link 'Edit equipment needs'
      within("#equipment-item-#{item.id}") { assert_link 'Correct device or shipping details' }
      take_screenshot('equipment-archived-application-history', html: true, full: true)
    end

    private

    def selection(need)
      { id: need.id, quantity: need.remaining_quantity, lock_version: need.lock_version }
    end

    def equipment_label(product)
      product.catalog_label
    end
  end
end
