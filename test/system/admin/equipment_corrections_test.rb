# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class EquipmentCorrectionsTest < ApplicationSystemTestCase
    test 'staff correct invalid shipment details and ship one of two identical devices' do
      item = create(:equipment_item)
      sibling = create(:equipment_item, application: item.application, product: item.product, purchase_order: item.purchase_order)
      system_test_sign_in(create(:admin), bypass_mfa_enrollment: true)
      install_stimulus_error_reporting
      visit admin_application_path(item.application)
      within("#equipment-item-#{item.id}") { click_link 'Correct device or shipping details' }
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
      assert_equal %w[ReplacementPackage ReplacementSerial 987654321012345 fedex awaiting_shipment],
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
      assert_equal [nil, nil, nil, nil, 'awaiting_shipment'], [item.reload.tracking_number, item.serial_number, item.imei, item.carrier, item.queue_status]
      take_screenshot('equipment-identifiers-cleared-after-retry', html: true, full: true)
      visit edit_admin_equipment_item_path(item)
      fill_in 'Date shipped', with: Date.current.strftime('%m/%d/%Y')
      fill_in 'Tracking number', with: 'OriginalPackage'
      select 'UPS', from: 'Carrier'
      fill_in 'Correction reason', with: 'Record individual device shipment'
      click_button 'Save equipment correction'
      assert_text 'Equipment item updated.'
      within("#equipment-item-#{item.id}") do
        assert_text 'Shipment recorded'
        assert_link 'Track package'
      end
      assert_nil sibling.reload.shipped_at
      assert_equal Date.current, item.reload.shipped_at
      visit admin_purchase_order_path(item.purchase_order)
      assert_text 'Partially shipped'
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
        assert_text 'Partially shipped'
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
      system_test_sign_in(create(:admin), bypass_mfa_enrollment: true)
      install_stimulus_error_reporting
      visit edit_admin_purchase_order_correction_path(item.purchase_order)
      observe_correction_submissions
      original_number = item.purchase_order.number
      fill_in 'PO number', with: 'Corrected PO'
      fill_in 'Correction reason', with: 'Correct the shared header reference'
      assert_no_difference('Event.count') do
        find_button('Review correction').double_click
        assert_text 'Review purchase order changes'
      end
      assert_correction_submission(0, review: true)
      assert_selector '#equipment-correction-impact-heading:focus', text: 'Review purchase order changes'
      assert_equal 1, page.evaluate_script('window.equipmentCorrectionEvents.streams')
      assert_equal original_number, item.purchase_order.reload.number
      assert_text '2 devices across 1 application, including 1 shipped device'
      assert_selector '.bg-warning-50 dt', text: 'PO number:', count: 1
      assert_selector '.bg-warning-50 dt', count: 1
      check 'I reviewed these changes for every device and application in this PO.'
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
      return_context = { tab: 'shipped', product_id: item.product_id.to_s }
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
      select replacement.catalog_label, from: 'Device model'
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
      assert_equal 'awaiting_shipment', item.queue_status
      within("#equipment-item-#{item.id}") { find('summary', text: 'Equipment correction history').click }
      assert_text 'Shipment date was entered in error'
      take_screenshot('equipment-shipment-date-corrected', html: true, full: true)
    end

    test 'detached devices reorder through a bid with the same physical identity' do
      item = create(:equipment_item, tracking_number: 'RecordedPackage')
      system_test_sign_in(create(:admin), bypass_mfa_enrollment: true)
      install_stimulus_error_reporting
      visit edit_admin_equipment_item_path(item)
      select 'Remove unshipped device from PO for reorder', from: 'Correction action'
      fill_in 'Tracking number', with: 'CorrectedPackage'
      fill_in 'Correction reason', with: 'Detach after correcting the package reference'
      assert_rejected_device_action(item, field: 'Tracking number', draft: 'CorrectedPackage')
      select 'Save device details', from: 'Correction action'
      click_button 'Save equipment correction'
      assert_text 'Equipment item updated.'
      visit edit_admin_equipment_item_path(item)
      select 'Remove unshipped device from PO for reorder', from: 'Correction action'
      fill_in 'Correction reason', with: 'Previous order no longer applies'
      click_button 'Save equipment correction'
      assert_nil item.reload.purchase_order_id
      assert_equal 'CorrectedPackage', item.tracking_number
      visit new_admin_bid_group_path(item_ids: [item.id])
      fill_in 'Bid number', with: 'REBID-BROWSER-DEVICE'
      click_button 'Reserve selected products under this bid'
      assert_text 'REBID-BROWSER-DEVICE'
      click_link 'Enter PO details for this bid'
      fill_in 'New PO number', with: 'REORDER-BROWSER-PO'
      click_button 'Save PO details'
      assert_text 'Award and unsent PO recorded.'
      assert_equal 'REORDER-BROWSER-PO', item.reload.purchase_order.number
      assert_equal 'CorrectedPackage', item.tracking_number
      assert_nil item.shipped_at
      take_screenshot('equipment-detached-device-rebid-awarded', html: true, full: true)
    end

    test 'staff review potential serial duplication without changing physical order provenance' do
      item = create(:equipment_item)
      another_model = create(:product, manufacturer: item.product.manufacturer, model_number: 'Other physical model')
      create(:equipment_item, product: another_model, serial_number: 'SHARED-SERIAL')
      system_test_sign_in(create(:admin), bypass_mfa_enrollment: true)
      visit edit_admin_equipment_item_path(item)
      fill_in 'Serial number', with: 'SHARED-SERIAL'
      fill_in 'Correction reason', with: 'Record the verified physical serial'
      click_button 'Save equipment correction'
      assert_text 'matches another model from this manufacturer'
      assert_field 'Serial number', with: 'SHARED-SERIAL'
      assert_nil item.reload.serial_number
      fill_in 'Reason for accepting a possible duplicate serial number', with: 'Verified the labels on two separate models.'
      click_button 'Save equipment correction'
      assert_text 'Equipment item updated.'
      assert_equal 'SHARED-SERIAL', item.reload.serial_number
      take_screenshot('equipment-serial-acknowledgment-retained', html: true, full: true)
    end

    test 'shared header invalid date and membership changes preserve the draft until explicit refresh' do
      order = create(:purchase_order)
      item = create(:equipment_item, purchase_order: order)
      create(:equipment_item, purchase_order: order)
      system_test_sign_in(create(:admin), bypass_mfa_enrollment: true)
      visit edit_admin_purchase_order_correction_path(order)
      fill_in 'PO number', with: 'CORRECTED-HEADER'
      fill_in 'Date PO sent', with: '13/45/2026'
      fill_in 'Correction reason', with: 'Correct actual header reference and sending date'
      click_button 'Review correction'
      check 'I reviewed these changes for every device and application in this PO.'
      click_button 'Save purchase order correction'
      assert_text 'Date PO sent is invalid'
      assert_field 'Date PO sent', with: '13/45/2026'
      assert_field 'PO number', with: 'CORRECTED-HEADER'
      fill_in 'Date PO sent', with: (Date.current - 1.day).strftime('%m/%d/%Y')
      click_button 'Review changed values'
      create(:equipment_item, purchase_order: order)
      check 'I reviewed these changes for every device and application in this PO.'
      click_button 'Save purchase order correction'
      assert_text 'Refresh'
      assert_field 'PO number', with: 'CORRECTED-HEADER'
      assert_not_equal 'CORRECTED-HEADER', order.reload.number
      take_screenshot('equipment-shared-header-membership-stale', html: true, full: true)
      click_link 'Refresh purchase order and discard this draft'
      fill_in 'PO number', with: 'CORRECTED-HEADER'
      fill_in 'Correction reason', with: 'Reviewed the complete current membership'
      click_button 'Review correction'
      check 'I reviewed these changes for every device and application in this PO.'
      click_button 'Save purchase order correction'
      assert_text 'Purchase order corrected.'
      assert_equal 'CORRECTED-HEADER', item.reload.purchase_order.number
    end

    test 'stale item forms reject unchanged retries until staff explicitly refresh' do
      item = create(:equipment_item)
      other_admin = create(:admin)
      system_test_sign_in(create(:admin), bypass_mfa_enrollment: true)
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
      click_link 'Refresh device and discard this draft'
      assert_field 'Tracking number', with: 'Other administrator package'
      assert_equal '1', find('input[name=expected_version]', visible: false).value
    end

    test 'expired correction reviews retain drafts and recover through a fresh review' do
      item = create(:equipment_item, shipped_at: Date.current, tracking_number: 'OriginalPackage')
      create(:equipment_item, application: item.application, purchase_order: item.purchase_order)
      context = { tab: 'shipped', product_id: item.product_id.to_s }
      scenarios = [
        { kind: 'item', record: item, path: edit_admin_equipment_item_path(item, return_context: context),
          field: 'Tracking number', attribute: :tracking_number, value: 'RecoveredPackage',
          confirmation: 'I confirm this correction and its impact on shipment history.', save: 'Save equipment correction', notice: 'Equipment item updated.' },
        { kind: 'header', record: item.purchase_order, path: edit_admin_purchase_order_correction_path(item.purchase_order, return_context: context),
          field: 'PO number', attribute: :number, value: 'RECOVERED-PO',
          confirmation: 'I reviewed these changes for every device and application in this PO.', save: 'Save purchase order correction', notice: 'Purchase order corrected.' }
      ]
      system_test_sign_in(create(:admin), bypass_mfa_enrollment: true)
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
        [name, input.value] if name == 'expected_version' || name.start_with?('item_versions[')
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
