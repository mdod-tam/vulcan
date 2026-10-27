# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class EquipmentCorrectionsTest < ApplicationSystemTestCase
    test 'staff correct invalid shipment details and ship one of two identical devices' do
      item = create(:equipment_item)
      sibling = create(:equipment_item, application: item.application, product: item.product, purchase_order: item.purchase_order)
      system_test_sign_in(create(:admin))
      install_stimulus_error_reporting
      visit admin_application_path(item.application)
      within("#equipment-item-#{item.id}") { click_link 'Correct device / record shipment' }
      fill_in 'Date shipped', with: '13/45/2026'
      fill_in 'Tracking number', with: 'OriginalPackage'
      fill_in 'Serial number', with: 'ShipmentSerial'
      fill_in 'IMEI (15 digits)', with: '123456789012345'
      select 'UPS', from: 'Carrier'
      fill_in 'Correction reason', with: 'Record individual device shipment'
      click_button 'Save equipment correction'
      assert_text 'Date shipped is invalid'
      assert_selector '#equipment-item-errors:focus'
      assert_selector '#equipment_item_shipped_at[aria-invalid=true][aria-describedby="equipment-ship-date-help equipment-ship-date-error"]'
      assert_field 'Date shipped', with: '13/45/2026'
      assert_field 'Tracking number', with: 'OriginalPackage'
      assert_field 'Serial number', with: 'ShipmentSerial'
      assert_field 'IMEI (15 digits)', with: '123456789012345'
      assert_select 'Carrier', selected: 'UPS'
      take_screenshot('equipment-shipment-invalid-retry', html: true, full: true)
      assert_no_difference -> { item.events.count } do
        click_button 'Save equipment correction'
        assert_text 'Date shipped is invalid'
        assert_selector '#equipment-item-errors:focus'
      end
      fill_in 'Date shipped', with: ''
      fill_in 'Tracking number', with: 'ReplacementPackage'
      fill_in 'Serial number', with: 'ReplacementSerial'
      fill_in 'IMEI (15 digits)', with: '987654321012345'
      select 'FedEx', from: 'Carrier'
      fill_in 'Correction reason', with: 'Replace restored device identifiers'
      click_button 'Save equipment correction'
      assert_text 'Equipment item updated.'
      assert_equal %w[ReplacementPackage ReplacementSerial 987654321012345 fedex ordered],
                   [item.reload.tracking_number, item.serial_number, item.imei, item.carrier, item.queue_status]
      visit edit_admin_equipment_item_path(item)
      fill_in 'Date shipped', with: (Date.current + 1.day).strftime('%m/%d/%Y')
      fill_in 'Correction reason', with: 'Verify restored identity values can be cleared'
      click_button 'Save equipment correction'
      assert_text 'cannot be in the future'
      fill_in 'Date shipped', with: ''
      fill_in 'Tracking number', with: ''
      fill_in 'Serial number', with: ''
      fill_in 'IMEI (15 digits)', with: ''
      select 'Not recorded', from: 'Carrier'
      fill_in 'Correction reason', with: 'Clear restored fields after invalid date'
      click_button 'Save equipment correction'
      assert_text 'Equipment item updated.'
      assert_equal [nil, nil, nil, nil, 'ordered'], [item.reload.tracking_number, item.serial_number, item.imei, item.carrier, item.queue_status]
      take_screenshot('equipment-identifiers-cleared-after-retry', html: true, full: true)
      visit edit_admin_equipment_item_path(item)
      fill_in 'Date shipped', with: Date.current.strftime('%m/%d/%Y')
      fill_in 'Tracking number', with: 'OriginalPackage'
      select 'UPS', from: 'Carrier'
      fill_in 'Correction reason', with: 'Record individual device shipment'
      click_button 'Save equipment correction'
      assert_text 'Equipment item updated.'
      within("#equipment-item-#{item.id}") do
        assert_text 'Shipped'
        assert_link 'Track package'
      end
      assert_nil sibling.reload.shipped_at
      assert_equal Date.current, item.reload.shipped_at
      visit admin_purchase_order_path(item.purchase_order)
      assert_text 'Partially Shipped'
      original_window = page.current_window
      original_url = page.current_url
      tracking_link = within("#equipment-item-#{item.id}") { find_link('Track package') }
      tracking_url = tracking_link[:href]
      assert_equal 'https://www.ups.com/track?loc=en_US&tracknum=OriginalPackage', tracking_url
      assert_equal '_blank', tracking_link[:target]
      assert_equal 'noopener noreferrer', tracking_link[:rel]
      assert_equal 'no-referrer', tracking_link[:referrerpolicy]
      assert_equal 'Track package with UPS (opens in a new tab)', tracking_link[:'aria-label']
      begin
        # Isolate native new-tab behavior from carrier scripts, downloads, and availability.
        page.execute_script('arguments[0].href = arguments[1]', tracking_link, URI.join(original_url, root_path).to_s)
        tracking_window = window_opened_by { tracking_link.click }
        within_window(tracking_window) { assert_selector 'main' }
        assert_equal original_window, page.current_window
        assert_equal original_url, page.current_url
        assert_text 'Partially Shipped'
        assert_equal Date.current, item.reload.shipped_at
      ensure
        tracking_window&.close
        page.execute_script('arguments[0].href = arguments[1]', tracking_link, tracking_url)
      end
      take_screenshot('equipment-single-device-shipped', html: true, full: true)
    end

    test 'shared PO and shipped device corrections review scope and retain equipment return filters' do
      item = create(:equipment_item, shipped_at: Date.current, tracking_number: 'OriginalPackage', carrier: 'usps')
      sibling = create(:equipment_item, application: item.application, product: item.product, purchase_order: item.purchase_order)
      replacement = create(:product, name: 'Corrected physical model')
      system_test_sign_in(create(:admin))
      install_stimulus_error_reporting
      visit edit_admin_purchase_order_correction_path(item.purchase_order)
      observe_correction_submissions
      original_number = item.purchase_order.number
      fill_in 'PO number', with: 'Corrected PO'
      fill_in 'Correction reason', with: 'Correct the shared header reference'
      assert_no_difference('Event.count') do
        find_button('Review correction').double_click
        assert_text 'Review old and new header values'
      end
      assert_correction_submission(0, review: true)
      assert_selector '#equipment-correction-impact-heading:focus', text: 'Review old and new header values'
      assert_equal 1, page.evaluate_script('window.equipmentCorrectionEvents.streams')
      assert_equal original_number, item.purchase_order.reload.number
      assert_text '2 equipment items across 1 application, including 1 shipped device'
      assert_selector '.bg-warning-50 dt', text: 'PO number:', count: 1
      assert_selector '.bg-warning-50 dt', count: 1
      check 'I confirm the impact on all linked equipment and applications.'
      take_screenshot('equipment-shared-po-impact', html: true, full: true)
      assert_difference -> { item.purchase_order.events.count }, 1 do
        find_button('Save purchase order correction').double_click
        assert_text 'Purchase order corrected.'
      end
      assert_correction_submission(1, review: false, confirmed: true)
      assert_current_path admin_purchase_order_path(item.purchase_order)
      assert_no_selector '#equipment-correction'
      assert_equal 'Corrected PO', sibling.reload.purchase_order.number
      take_screenshot('equipment-shared-po-corrected', html: true, full: true)
      return_context = { tab: 'shipped', product_id: item.product_id.to_s, vendor_id: item.purchase_order.vendor_id.to_s }
      visit edit_admin_equipment_item_path(item, return_context: return_context)
      observe_correction_submissions
      fill_in 'Tracking number', with: 'CorrectedPackage'
      fill_in 'Correction reason', with: 'Correct the individual parcel reference'
      assert_no_difference('Event.count') do
        find_button('Review correction').double_click
        assert_text 'OriginalPackage → CorrectedPackage'
      end
      assert_correction_submission(0, review: true)
      assert_selector '#equipment-correction-impact-heading:focus', text: 'Correction impact: 1 device across 1 application'
      assert_equal 1, page.evaluate_script('window.equipmentCorrectionEvents.streams')
      assert_equal 'OriginalPackage', item.reload.tracking_number
      assert_selector '.bg-warning-50 dt', text: 'Tracking number:', count: 1
      assert_selector '.bg-warning-50 dt', count: 1
      reviewed_token = find('input[name=impact_token]', visible: false).value
      fill_in 'Tracking number', with: 'ReviewedAgainPackage'
      check 'I confirm this correction and its impact on shipment history.'
      click_button 'Save equipment correction'
      assert_text 'Review the current correction values and confirm their impact before saving.'
      assert_correction_submission(1, review: false, confirmed: true)
      assert_selector '#equipment-item-errors:focus'
      assert_field 'Tracking number', with: 'ReviewedAgainPackage'
      assert_field 'Correction reason', with: 'Correct the individual parcel reference'
      assert_equal reviewed_token, find('input[name=impact_token]', visible: false).value
      assert_unchecked_field 'I confirm this correction and its impact on shipment history.'
      assert_button 'Save equipment correction', disabled: false
      take_screenshot('equipment-correction-token-invalid-retry', html: true, full: true)
      select "#{replacement.manufacturer} / #{replacement.name} / #{replacement.model_number}", from: 'Actual catalog product'
      select 'FedEx', from: 'Carrier'
      fill_in 'IMEI (15 digits)', with: '123456789012345'
      find_button('Review changed values').double_click
      assert_selector '.bg-warning-50 dd', text: 'USPS → FedEx'
      assert_correction_submission(2, review: true)
      assert_selector '#equipment-correction-impact-heading:focus'
      assert_equal 2, page.evaluate_script('window.equipmentCorrectionEvents.streams')
      assert_not_equal reviewed_token, find('input[name=impact_token]', visible: false).value
      assert_selector '.bg-warning-50 dt', text: 'IMEI (15 digits):'
      assert_selector '.bg-warning-50 dt', count: 4
      check 'I confirm this correction and its impact on shipment history.'
      take_screenshot('equipment-shipped-correction-review', html: true, full: true)
      find_button('Save equipment correction').double_click
      assert_text 'Equipment item updated.'
      assert_correction_submission(3, review: false, confirmed: true)
      assert_current_path admin_equipment_index_path(return_context)
      assert_no_selector '#equipment-correction'
      assert_equal Date.current, item.reload.shipped_at
      assert_equal replacement.id, item.product_id
      assert_equal 'ReviewedAgainPackage', item.tracking_number
      assert_equal 'fedex', item.carrier
      assert_equal '123456789012345', item.imei
      assert_nil sibling.reload.shipped_at
      visit edit_admin_equipment_item_path(item)
      fill_in 'Date shipped', with: ''
      fill_in 'Correction reason', with: 'Shipment date was entered in error'
      click_button 'Review correction'
      assert_selector '.bg-warning-50 dt', text: 'Date shipped:'
      assert_selector '.bg-warning-50 dd', text: "#{Date.current.strftime('%m/%d/%Y')} → Not recorded"
      check 'I confirm this correction and its impact on shipment history.'
      click_button 'Save equipment correction'
      assert_text 'Equipment item updated.'
      assert_nil item.reload.shipped_at
      assert_equal 'ordered', item.queue_status
      within("#equipment-item-#{item.id}") { find('summary', text: 'Equipment correction history').click }
      assert_text 'Shipment date was entered in error'
      take_screenshot('equipment-shipment-date-corrected', html: true, full: true)
    end

    test 'detached devices reorder with the same identity and withdrawal retains history' do
      item = create(:equipment_item, tracking_number: 'RecordedPackage')
      replacement_order = create(:purchase_order)
      system_test_sign_in(create(:admin))
      install_stimulus_error_reporting
      visit edit_admin_equipment_item_path(item)
      select 'Detach an unshipped device for reorder', from: 'Correction action'
      fill_in 'Tracking number', with: 'CorrectedPackage'
      fill_in 'Correction reason', with: 'Ordered with the wrong vendor'
      assert_rejected_device_action(item, field: 'Tracking number', draft: 'CorrectedPackage')
      assert_select 'Correction action', selected: 'Detach an unshipped device for reorder'
      assert_field 'Correction reason', with: 'Ordered with the wrong vendor'
      take_screenshot('equipment-detach-edited-draft-rejected', html: true, full: true)
      select 'Save device details or move purchase order', from: 'Correction action'
      fill_in 'Correction reason', with: 'Correct package details before detaching'
      original_order_id = item.purchase_order_id
      click_button 'Save equipment correction'
      assert_text 'Equipment item updated.'
      assert_equal 'CorrectedPackage', item.reload.tracking_number
      assert_equal original_order_id, item.purchase_order_id
      within("#equipment-item-#{item.id}") { click_link 'Correct device / record shipment' }
      select 'Detach an unshipped device for reorder', from: 'Correction action'
      fill_in 'Correction reason', with: 'Ordered with the wrong vendor'
      click_button 'Save equipment correction'
      assert_text 'Previously ordered device awaiting reorder'
      assert_nil item.reload.purchase_order_id
      assert_equal 'CorrectedPackage', item.tracking_number
      within("#equipment-item-#{item.id}") { click_link 'Correct device / record shipment' }
      select "#{replacement_order.vendor.business_name} / #{replacement_order.number}", from: 'Current purchase order'
      fill_in 'Correction reason', with: 'Reorder the same device'
      click_button 'Save equipment correction'
      assert_equal replacement_order.id, item.reload.purchase_order_id
      within("#equipment-item-#{item.id}") { click_link 'Correct device / record shipment' }
      select 'Detach an unshipped device for reorder', from: 'Correction action'
      fill_in 'Correction reason', with: 'No longer intended for purchase'
      click_button 'Save equipment correction'
      within("#equipment-item-#{item.id}") { click_link 'Correct device / record shipment' }
      select 'Withdraw a detached unshipped device', from: 'Correction action'
      fill_in 'Serial number', with: 'CorrectedDetachedSerial'
      fill_in 'Correction reason', with: 'Staff confirmed the device is no longer needed'
      assert_rejected_device_action(item, field: 'Serial number', draft: 'CorrectedDetachedSerial')
      assert_select 'Correction action', selected: 'Withdraw a detached unshipped device'
      assert_field 'Correction reason', with: 'Staff confirmed the device is no longer needed'
      take_screenshot('equipment-withdraw-edited-draft-rejected', html: true, full: true)
      select 'Save device details or move purchase order', from: 'Correction action'
      fill_in 'Correction reason', with: 'Correct serial details before withdrawing'
      click_button 'Save equipment correction'
      assert_text 'Equipment item updated.'
      assert_equal 'CorrectedDetachedSerial', item.reload.serial_number
      assert_nil item.purchase_order_id
      assert_nil item.withdrawn_at
      within("#equipment-item-#{item.id}") { click_link 'Correct device / record shipment' }
      select 'Withdraw a detached unshipped device', from: 'Correction action'
      fill_in 'Correction reason', with: 'Staff confirmed the device is no longer needed'
      click_button 'Save equipment correction'
      within("#equipment-item-#{item.id}") do
        assert_text 'Withdrawn'
        assert_no_link 'Correct device / record shipment'
        find('summary', text: 'Equipment correction history').click
      end
      assert item.reload.withdrawn_at?
      assert_equal 6, item.events.count
      assert_equal 'CorrectedPackage', item.tracking_number
      assert_equal 'CorrectedDetachedSerial', item.serial_number
      assert_text 'Reorder the same device'
      take_screenshot('equipment-withdrawn-device-history', html: true, full: true)
    end

    test 'inline order retry can switch to an existing PO and staff review potential serial duplication' do
      item = create(:equipment_item)
      target_order = create(:purchase_order)
      admin = create(:admin)
      system_test_sign_in(admin)
      install_stimulus_error_reporting
      visit edit_admin_equipment_item_path(item)
      find('summary', text: 'Move to a new purchase order').click
      check 'Create a purchase order for this device'
      select target_order.vendor.business_name, from: 'New Vendor'
      fill_in 'New PO number', with: 'Inline Retry Header'
      fill_in 'New Date PO sent', with: '13/45/2026'
      fill_in 'Tracking number', with: 'InlineRetryPackage'
      fill_in 'Correction reason', with: 'Review an inline header'
      assert_no_difference ['PurchaseOrder.count', 'Event.count'] do
        click_button 'Save equipment correction'
        assert_text 'is invalid'
      end
      assert_checked_field 'Create a purchase order for this device'
      assert_select 'New Vendor', selected: target_order.vendor.business_name
      assert_field 'New PO number', with: 'Inline Retry Header'
      assert_field 'New Date PO sent', with: '13/45/2026'
      assert_selector '#new_purchase_order_sent_at[aria-invalid=true][aria-describedby="new_purchase_order_sent_at-help new_purchase_order_sent_at-error"]'
      assert_selector '#new_purchase_order_sent_at-error', text: /Date PO sent is invalid/
      assert_field 'Tracking number', with: 'InlineRetryPackage'
      take_screenshot('equipment-inline-order-invalid-retry', html: true, full: true)
      select item.purchase_order.vendor.business_name, from: 'New Vendor'
      fill_in 'New PO number', with: 'Corrected Inline Header'
      fill_in 'New Date PO sent', with: (Date.current - 1.day).strftime('%m/%d/%Y')
      click_button 'Save equipment correction'
      assert_text 'Equipment item updated.'
      assert_equal ['Corrected Inline Header', Date.current - 1.day], [item.reload.purchase_order.number, item.purchase_order.sent_at]
      visit edit_admin_equipment_item_path(item)
      find('summary', text: 'Move to a new purchase order').click
      check 'Create a purchase order for this device'
      select target_order.vendor.business_name, from: 'New Vendor'
      fill_in 'New PO number', with: 'Second Inline Retry'
      fill_in 'New Date PO sent', with: '13/45/2026'
      fill_in 'Correction reason', with: 'Switch a restored create branch to the existing header'
      click_button 'Save equipment correction'
      assert_text 'is invalid'
      uncheck 'Create a purchase order for this device'
      select "#{target_order.vendor.business_name} / #{target_order.number}", from: 'Current purchase order'
      click_button 'Save equipment correction'
      assert_text 'Equipment item updated.'
      assert_equal target_order.id, item.reload.purchase_order_id
      assert_equal 'InlineRetryPackage', item.tracking_number
      other_model = create(:product, manufacturer: item.product.manufacturer, model_number: 'Other serial model')
      conflict = create(:equipment_item, product: other_model, serial_number: 'SharedModelSerial')
      context = { tab: 'ordered', product_id: item.product_id.to_s, vendor_id: target_order.vendor_id.to_s }
      visit edit_admin_equipment_item_path(item, return_context: context)
      fill_in 'Serial number', with: 'SharedModelSerial'
      fill_in 'Correction reason', with: 'Review manufacturer serial reuse'
      click_button 'Save equipment correction'
      assert_text 'matches another model from this manufacturer'
      take_screenshot('equipment-potential-serial-warning', html: true, full: true)
      click_link "Review equipment item ##{conflict.id}"
      assert_current_path edit_admin_equipment_item_path(conflict, return_context: context)
      assert_field 'Serial number', with: 'SharedModelSerial'
      visit edit_admin_equipment_item_path(item)
      fill_in 'Serial number', with: 'SharedModelSerial'
      fill_in 'Correction reason', with: 'Reviewed the other physical device'
      click_button 'Save equipment correction'
      assert_text 'matches another model from this manufacturer'
      fill_in 'Potential serial duplicate acknowledgment reason', with: 'Different models legitimately reuse this manufacturer serial'
      click_button 'Save equipment correction'
      assert_text 'Equipment item updated.'
      assert_equal 'SharedModelSerial', item.reload.serial_number
      within("#equipment-item-#{item.id}") { find('summary', text: 'Equipment correction history').click }
      assert_text 'Different models legitimately reuse this manufacturer serial'
      take_screenshot('equipment-serial-warning-acknowledged', html: true, full: true)
    end

    test 'shared header error restores vendor and date choices and changed membership requires explicit refresh' do
      item = create(:equipment_item)
      order = item.purchase_order
      create(:equipment_item, application: item.application, purchase_order: order)
      first_vendor = create(:vendor)
      final_vendor = create(:vendor)
      admin = create(:admin)
      system_test_sign_in(admin)
      install_stimulus_error_reporting
      visit edit_admin_purchase_order_correction_path(order)
      select first_vendor.business_name, from: 'Vendor'
      fill_in 'PO number', with: 'Header Retry Number'
      fill_in 'Date PO sent', with: '13/45/2026'
      fill_in 'Correction reason', with: 'Correct the shared vendor and date'
      click_button 'Review correction'
      check 'I confirm the impact on all linked equipment and applications.'
      click_button 'Save purchase order correction'
      assert_text 'is invalid'
      assert_selector '#purchase-order-correction-errors:focus'
      assert_select 'Vendor', selected: first_vendor.business_name
      assert_field 'Date PO sent', with: '13/45/2026'
      assert_field 'PO number', with: 'Header Retry Number'
      assert_selector '#purchase_order_sent_at[aria-invalid=true][aria-describedby="purchase_order_sent_at-help purchase_order_sent_at-error"]'
      assert_selector '#purchase_order_sent_at-error', text: /Date PO sent is invalid/
      assert_no_difference -> { order.events.count } do
        check 'I confirm the impact on all linked equipment and applications.'
        click_button 'Save purchase order correction'
        assert_text 'is invalid'
        assert_selector '#purchase-order-correction-errors:focus'
      end
      take_screenshot('equipment-shared-header-invalid-retry', html: true, full: true)
      select final_vendor.business_name, from: 'Vendor'
      fill_in 'Date PO sent', with: (Date.current - 1.day).strftime('%m/%d/%Y')
      fill_in 'Correction reason', with: 'Replace restored shared vendor and date'
      click_button 'Review changed values'
      assert_selector '.bg-warning-50 dd', text: final_vendor.business_name
      check 'I confirm the impact on all linked equipment and applications.'
      click_button 'Save purchase order correction'
      assert_text 'Purchase order corrected.'
      assert_equal [final_vendor.id, Date.current - 1.day], [order.reload.vendor_id, order.sent_at]
      visit edit_admin_purchase_order_correction_path(order)
      fill_in 'PO number', with: 'Stale scalar draft'
      fill_in 'Correction reason', with: 'Review the current shared header'
      click_button 'Review correction'
      reviewed_header_token = find('input[name=impact_token]', visible: false).value
      item_versions = order.equipment_items.to_h { |member| [member.id.to_s, member.lock_version.to_s] }
      header_attributes = { number: 'Other administrator header' }
      token = Equipment::Correction.impact_token(record: order, attributes: header_attributes, extra: { item_versions: item_versions })
      Equipment::Correction.new(actor: create(:admin)).update_purchase_order!(purchase_order: order, attributes: header_attributes,
                                                                              expected_version: order.lock_version, expected_item_versions: item_versions,
                                                                              reason: 'Another administrator corrected the header', confirmed_impact: true, impact_token: token)
      2.times do
        assert_no_difference -> { order.events.count } do
          check 'I confirm the impact on all linked equipment and applications.'
          click_button 'Save purchase order correction'
          assert_text 'Equipment changed. Refresh and review your selection.'
          assert_selector '#purchase-order-correction-errors:focus'
        end
        assert_field 'PO number', with: 'Stale scalar draft'
        assert_field 'Correction reason', with: 'Review the current shared header'
        assert_equal '1', find('input[name=expected_version]', visible: false).value
        assert_equal reviewed_header_token, find('input[name=impact_token]', visible: false).value
        assert_button 'Save purchase order correction', disabled: false
      end
      take_screenshot('equipment-shared-header-version-stale-retry', html: true, full: true)
      click_link 'Refresh purchase order and discard this draft'
      assert_field 'PO number', with: 'Other administrator header'
      assert_equal '2', find('input[name=expected_version]', visible: false).value
      fill_in 'PO number', with: 'Stale scope draft'
      fill_in 'Correction reason', with: 'Review shared scope'
      click_button 'Review correction'
      reviewed_scope_token = find('input[name=impact_token]', visible: false).value
      extra_item = create(:equipment_item, application: item.application, purchase_order: nil)
      Equipment::Correction.new(actor: admin).update_item!(item: extra_item, attributes: { purchase_order_id: order.id },
                                                           expected_version: 0, purchase_order_versions: { order.id => order.lock_version }, reason: 'Another tab links a queued device')
      2.times do
        assert_no_difference -> { order.events.count } do
          check 'I confirm the impact on all linked equipment and applications.'
          click_button 'Save purchase order correction'
          assert_text 'Purchase order membership changed. Refresh and review its impact.'
          assert_selector '#purchase-order-correction-errors:focus'
        end
        assert_equal reviewed_scope_token, find('input[name=impact_token]', visible: false).value
        assert_button 'Save purchase order correction', disabled: false
      end
      assert_field 'PO number', with: 'Stale scope draft'
      take_screenshot('equipment-shared-membership-stale-retry', html: true, full: true)
      click_link 'Refresh purchase order and discard this draft'
      assert_field 'PO number', with: 'Other administrator header'
      fill_in 'PO number', with: 'Refreshed scope header'
      fill_in 'Correction reason', with: 'Confirm expanded shared order'
      click_button 'Review correction'
      assert_text '3 equipment items across 1 application'
      check 'I confirm the impact on all linked equipment and applications.'
      click_button 'Save purchase order correction'
      assert_text 'Purchase order corrected.'
      assert_equal 'Refreshed scope header', extra_item.reload.purchase_order.number
      take_screenshot('equipment-shared-membership-refreshed', html: true, full: true)
    end

    test 'stale item and target PO forms reject unchanged retries until staff explicitly refresh' do
      item = create(:equipment_item)
      original_order_id = item.purchase_order_id
      target_order = create(:purchase_order)
      other_admin = create(:admin)
      system_test_sign_in(create(:admin))
      install_stimulus_error_reporting
      visit edit_admin_equipment_item_path(item)
      fill_in 'Tracking number', with: 'Stale browser draft'
      fill_in 'Correction reason', with: 'Older device form'
      Equipment::Correction.new(actor: other_admin).update_item!(item: item, attributes: { tracking_number: 'Other administrator package' },
                                                                 expected_version: 0, reason: 'Another staff member corrected this device')
      2.times do
        assert_no_difference -> { item.events.count } do
          click_button 'Save equipment correction'
          assert_text 'Equipment changed. Refresh and review your selection.'
        end
        assert_field 'Tracking number', with: 'Stale browser draft'
        assert_equal '0', find('input[name=expected_version]', visible: false).value
      end
      assert_equal 'Other administrator package', item.reload.tracking_number
      take_screenshot('equipment-stale-item-unchanged-retry', html: true, full: true)
      click_link 'Refresh equipment item and discard this draft'
      assert_field 'Tracking number', with: 'Other administrator package'
      assert_equal '1', find('input[name=expected_version]', visible: false).value
      assert_equal '0', find("input[name='purchase_order_versions[#{target_order.id}]']", visible: false).value
      select "#{target_order.vendor.business_name} / #{target_order.number}", from: 'Current purchase order'
      fill_in 'Correction reason', with: 'Move to the selected existing header'
      Equipment::Correction.new(actor: other_admin).update_purchase_order!(purchase_order: target_order, attributes: { number: 'Revised target header' },
                                                                           expected_version: 0, expected_item_versions: {}, reason: 'Another staff member corrected the target header')
      2.times do
        assert_no_difference -> { item.events.count } do
          click_button 'Save equipment correction'
          assert_text 'Equipment changed. Refresh and review your selection.'
        end
        assert_equal '0', find("input[name='purchase_order_versions[#{target_order.id}]']", visible: false).value
        assert_equal original_order_id, item.reload.purchase_order_id
      end
      take_screenshot('equipment-stale-target-po-unchanged-retry', html: true, full: true)
      click_link 'Refresh equipment item and discard this draft'
      assert_equal '1', find("input[name='purchase_order_versions[#{target_order.id}]']", visible: false).value
      select "#{target_order.vendor.business_name} / #{target_order.reload.number}", from: 'Current purchase order'
      fill_in 'Correction reason', with: 'Reviewed the refreshed target header'
      click_button 'Save equipment correction'
      assert_text 'Equipment item updated.'
      assert_equal target_order.id, item.reload.purchase_order_id
      assert_equal 'Other administrator package', item.tracking_number
      take_screenshot('equipment-stale-fences-refreshed', html: true, full: true)
    end

    test 'expired correction reviews retain drafts and recover through a fresh review' do
      item = create(:equipment_item, shipped_at: Date.current, tracking_number: 'OriginalPackage')
      create(:equipment_item, application: item.application, purchase_order: item.purchase_order)
      context = { tab: 'shipped', product_id: item.product_id.to_s, vendor_id: item.purchase_order.vendor_id.to_s }
      scenarios = [
        { kind: 'item', record: item, path: edit_admin_equipment_item_path(item, return_context: context),
          field: 'Tracking number', attribute: :tracking_number, value: 'RecoveredPackage',
          confirmation: 'I confirm this correction and its impact on shipment history.', save: 'Save equipment correction', notice: 'Equipment item updated.' },
        { kind: 'header', record: item.purchase_order, path: edit_admin_purchase_order_correction_path(item.purchase_order, return_context: context),
          field: 'PO number', attribute: :number, value: 'RECOVERED-PO',
          confirmation: 'I confirm the impact on all linked equipment and applications.', save: 'Save purchase order correction', notice: 'Purchase order corrected.' }
      ]
      system_test_sign_in(create(:admin))
      install_stimulus_error_reporting

      scenarios.each do |scenario|
        visit scenario[:path]
        fill_in scenario[:field], with: scenario[:value]
        fill_in 'Correction reason', with: 'Correct the recorded reference'
        click_button 'Review correction'
        assert_selector '#equipment-correction-impact-heading:focus'
        token = find('input[name=impact_token]', visible: false).value
        fences = correction_form_versions
        recorded = scenario[:record].reload.attributes

        travel 31.minutes do
          check scenario[:confirmation]
          assert_no_difference 'Event.count' do
            click_button scenario[:save]
            assert_text 'This correction review is no longer valid. Review the current values again before saving.'
          end
          assert_selector '[role=alert]:focus'
          assert_no_selector 'input[name=impact_token]', visible: :all
          assert_no_selector 'input[name=confirmed_impact]', visible: :all
          assert_no_button scenario[:save]
          assert_button 'Review correction', disabled: false
          assert_field scenario[:field], with: scenario[:value]
          assert_field 'Correction reason', with: 'Correct the recorded reference'
          assert_equal fences, correction_form_versions
          context.each { |key, value| assert_selector "input[name='return_context[#{key}]'][value='#{value}']", visible: :all }
          assert_equal recorded, scenario[:record].reload.attributes
          take_screenshot("equipment-#{scenario[:kind]}-review-expired", html: true, full: true)

          click_button 'Review correction'
          assert_selector '#equipment-correction-impact-heading:focus'
          assert_not_equal token, find('input[name=impact_token]', visible: false).value
          assert_equal fences, correction_form_versions
          assert_unchecked_field scenario[:confirmation]
          check scenario[:confirmation]
          take_screenshot("equipment-#{scenario[:kind]}-review-renewed", html: true, full: true)
          assert_difference 'Event.count', 1 do
            click_button scenario[:save]
            assert_text scenario[:notice]
          end
          assert_equal scenario[:value], scenario[:record].reload.public_send(scenario[:attribute])
          take_screenshot("equipment-#{scenario[:kind]}-review-recovered", html: true, full: true)
        end
      end
    end

    private

    def correction_form_versions
      all('#equipment-correction input[type=hidden]', visible: :all).filter_map do |input|
        name = input[:name]
        [name, input.value] if name == 'expected_version' || name.start_with?('purchase_order_versions[', 'item_versions[')
      end.to_h
    end

    def observe_correction_submissions
      page.execute_script(<<~JS)
        window.equipmentCorrectionObserver?.abort();
        window.equipmentCorrectionObserver = new AbortController();
        const options = {signal: window.equipmentCorrectionObserver.signal};
        window.equipmentCorrectionEvents = {submissions: [], streams: 0};
        document.addEventListener('turbo:submit-start', event => {
          if (!event.target.closest('#equipment-correction')) return;
          const submission = event.detail.formSubmission, submitter = submission.submitter;
          window.equipmentCorrectionEvents.submissions.push({
            disabled: submitter.disabled,
            label: submitter.matches('input') ? submitter.value : submitter.textContent.trim(),
            review: submission.body.get('review'),
            confirmed: submission.body.get('confirmed_impact') === '1'
          });
        }, options);
        document.addEventListener('turbo:before-stream-render', event => {
          if (event.target.getAttribute('target') === 'equipment-correction') {
            window.equipmentCorrectionEvents.streams += 1;
          }
        }, options);
      JS
    end

    def assert_correction_submission(index, review:, confirmed: false)
      submissions = page.evaluate_script('window.equipmentCorrectionEvents.submissions')
      assert_equal index + 1, submissions.size
      assert_equal({ 'disabled' => true, 'label' => review ? 'Reviewing...' : 'Saving...',
                     'review' => review ? '1' : nil, 'confirmed' => confirmed }, submissions.fetch(index))
    end

    def assert_rejected_device_action(item, field:, draft:)
      recorded = item.reload.attributes
      2.times do
        assert_no_difference('Event.count') do
          click_button 'Save equipment correction'
          assert_selector '#equipment-item-errors:focus', text: 'Detach and withdraw do not change device details. Save device details separately.'
        end
        assert_field field, with: draft
        assert_equal recorded, item.reload.attributes
      end
    end
  end
end
