# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class EquipmentMvpTest < ApplicationSystemTestCase
    include IcanconnectTestSupport

    setup do
      start_icanconnect!
      FeatureFlag.disable!(:vouchers_enabled)
      ensure_system_audit_actor!
      @admin = create(:admin)
      @product = create(:product, name: 'MVP exact tablet')
    end

    test 'application devices show mixed funding while filing preparation stays global' do
      application = approved_deafblind_application
      icc_product = Product.find_by!(manufacturer: 'Tatum Robotics', model_number: 'Tatum1')
      mat_product = create(:product, name: 'Brailliant', manufacturer: 'HumanWare', model_number: 'Brailliant')
      icc_order = create(:purchase_order, funding_source: 'icanconnect')
      icc = create(:equipment_item, application:, product: icc_product, purchase_order: icc_order,
                                    funding_source: 'icanconnect', disability_setup_group: 'deafblind')
      mat = create(:equipment_item, application:, product: mat_product, funding_source: 'mat', disability_setup_group: 'deafblind')
      system_test_sign_in(@admin, bypass_mfa_enrollment: true)

      visit admin_application_path(application)
      within('#equipment') do
        assert_selector "#equipment-item-#{icc.id} h4", text: /Tatum1 \(ICC\)/
        assert_selector "#equipment-item-#{mat.id} h4", text: /Brailliant \(MAT\)/
        assert_no_link 'iCanConnect filing preparation'
      end
      take_screenshot('application-mixed-device-funding', html: true, full: true)
      page.current_window.resize_to(390, 844)
      take_screenshot('application-mixed-device-funding-narrow', html: true, full: true)
      assert_operator page.evaluate_script('document.documentElement.scrollWidth'), :<=, 390
    ensure
      page.current_window.resize_to(1200, 800)
    end

    test 'replacing ICC equipment with MAT stock requires acknowledgement and retains it after an inventory retry' do
      application = approved_deafblind_application
      evaluation = create(:evaluation, :completed, application: application)
      detached = create(:equipment_item, application: application, product: @product, source_evaluation: evaluation,
                                         purchase_order: nil, funding_source: 'icanconnect', disability_setup_group: 'deafblind')
      system_test_sign_in(@admin, bypass_mfa_enrollment: true)
      visit new_admin_stock_allocation_path(item_ids: [detached.id])
      assert_text 'These stock devices keep MAT funding'
      assert_unchecked_field 'I understand these stock devices use MAT funding.'
      take_screenshot('icc-replacement-mat-stock-review', full: true, html: true)
      click_button 'Reserve for dispatch'
      assert_selector '#allocation_confirm_mat_funding:invalid'
      assert_nil detached.reload.withdrawn_at
      check 'I understand these stock devices use MAT funding.'
      click_button 'Reserve for dispatch'
      assert_text 'Available stock changed. Review quantities; no partial allocation was made.'
      assert_checked_field 'I understand these stock devices use MAT funding.'
      assert_nil detached.reload.withdrawn_at
      take_screenshot('icc-replacement-mat-stock-acknowledgement-retained', full: true, html: true)
      stock = Equipment::StockReceipt.new(actor: @admin).existing!(product: @product, quantity: 1, received_on: Date.current,
                                                                   provenance: 'Verified MAT stock for retry').sole
      click_button 'Reserve for dispatch'
      assert_text 'Stock reserved for dispatch.'
      assert_current_path admin_equipment_index_path(tab: 'ordered', source: 'stock')
      assert_equal stock.id, detached.reload.replaced_by_equipment_item_id
      assert_equal 'mat', stock.reload.funding_source
      assert_equal evaluation.id, stock.source_evaluation_id
      assert_equal 'icanconnect', detached.funding_source
      take_screenshot('icc-replacement-mat-stock-reserved', full: true, html: true)
    end

    test 'a reserved setup can be confirmed and an emptied bid reused before award' do
      application = equipment_application
      need = create(:equipment_need, application: application, product: @product, disability_setup_group: nil)
      system_test_sign_in(@admin, bypass_mfa_enrollment: true)
      visit admin_equipment_index_path(application_id: application.id, tab: 'needs_ordering')
      check "equipment-row-EquipmentNeed-#{need.id}"
      click_button 'Enter bid number'
      fill_in 'Bid number', with: 'RECOVERABLE-BID'
      click_button 'Reserve selected products under this bid'
      bid = BidGroup.find_by!(number: 'RECOVERABLE-BID')
      click_link 'Enter PO details for this bid'
      assert_text 'Setup needed'
      click_link 'Review equipment'
      select 'Deaf', from: 'equipment-need-setup-0'
      fill_in 'Reason for adjustment', with: 'Confirmed the constituent’s device setup before award'
      take_screenshot('reserved-setup-confirmation-review', html: true, full: true)
      click_button 'Save purchasing needs'
      assert_equal 'deaf', need.reload.disability_setup_group
      assert_equal bid.id, need.bid_group_lines.reserved.sole.bid_group_id
      visit admin_bid_group_path(bid)
      assert_text 'This bid has changed. Review the products and quantities before awarding it.'
      take_screenshot('reserved-setup-bid-review', html: true, full: true)
      check 'Release this reservation'
      fill_in 'Reason for change', with: 'Waiting for a corrected quote for this model'
      click_button 'Release selected reservations'
      assert_text 'No products are reserved under this bid.'
      assert_no_link 'Enter PO details for this bid'
      assert_no_button 'Save quantities'
      assert bid.reload.open?
      take_screenshot('empty-bid-reusable', html: true, full: true)
      click_link 'Choose products'
      check "equipment-row-EquipmentNeed-#{need.id}"
      click_button 'Enter bid number'
      select 'RECOVERABLE-BID · Direct to constituents · MAT', from: 'Or add these products to an open bid'
      click_button 'Reserve selected products under this bid'
      assert_current_path admin_bid_group_path(bid), ignore_query: true
      assert_equal 1, BidGroup.where(number: 'RECOVERABLE-BID').count
      assert_equal 1, bid.reload.active_lines.count
      assert_equal 1, bid.bid_group_lines.where.not(released_at: nil).count
      take_screenshot('empty-bid-products-readded', html: true, full: true)
      click_link 'Enter PO details for this bid'
      fill_in 'New PO number', with: 'RECOVERED-PO'
      click_button 'Save PO details'
      assert_selector 'h1', text: 'Purchase order RECOVERED-PO'
      order = PurchaseOrder.find_by!(number: 'RECOVERED-PO')
      assert_equal order.id, bid.reload.purchase_order_id
      assert_equal ['deaf'], order.equipment_items.pluck(:disability_setup_group)
      assert_equal 0, need.reload.remaining_quantity
      take_screenshot('reserved-setup-bid-awarded', html: true, full: true)
    end

    test 'awarding a bid records the vendor and each device price while keeping invalid entries for retry' do
      application = equipment_application
      priced = create(:equipment_need, application: application, product: @product, remaining_quantity: 2)
      unknown = create(:equipment_need, application: application, product: create(:product, name: 'Quote price not yet known'))
      bid = Equipment::Bidding.new(actor: @admin).create!(number: 'QUOTED-BID', needs: [need_row(priced).merge(quantity: 2), need_row(unknown)])
      priced_line = bid.active_lines.find_by!(equipment_need: priced)
      unknown_line = bid.active_lines.find_by!(equipment_need: unknown)
      create(:purchase_order, vendor_name: 'Previous Quote Supplier')
      system_test_sign_in(@admin, bypass_mfa_enrollment: true)
      visit admin_applications_path(view: 'pipeline', stage: 'awaiting_bid_award')
      within("tr#application_#{application.id}") { click_link 'Enter PO details' }
      context = { application_id: application.id, tab: 'needs_ordering' }
      assert_current_path new_admin_purchase_order_path(bid_group_id: bid.id, return_context: context)
      assert_link 'Back to Bid', href: admin_bid_group_path(bid, return_context: context)
      take_screenshot('pipeline-bid-opens-po-entry', html: true, full: true)
      assert_selector '#purchase-order-vendors option[value="Previous Quote Supplier"]', visible: :all
      assert_no_selector 'input[name*="imei"], input[name*="serial_number"]'
      fill_in 'New PO number', with: 'QUOTED-PO'
      fill_in 'Vendor name', with: 'Awarded Quote Supplier'
      fill_in "line-unit-cost-#{priced_line.id}", with: '12.345'
      click_button 'Save PO details'
      assert_text 'Enter a valid price per device in dollars and cents, or leave it blank.'
      assert_field 'New PO number', with: 'QUOTED-PO'
      assert_field 'Vendor name', with: 'Awarded Quote Supplier'
      assert_field "line-unit-cost-#{priced_line.id}", with: '12.345'
      assert_field "line-unit-cost-#{unknown_line.id}", with: ''
      assert bid.reload.open?
      assert_equal 2, priced.reload.remaining_quantity
      take_screenshot('bid-award-price-retry', html: true, full: true)
      page.current_window.resize_to(390, 844)
      take_screenshot('bid-award-price-retry-narrow', html: true, full: true)
      assert_operator page.evaluate_script('document.documentElement.scrollWidth'), :<=, 390
      fill_in "line-unit-cost-#{priced_line.id}", with: '$1,234.50'
      click_button 'Save PO details'
      assert_selector 'h1', text: 'Purchase order QUOTED-PO'
      order = PurchaseOrder.find_by!(number: 'QUOTED-PO')
      assert_equal 'Awarded Quote Supplier', order.vendor_name
      assert_equal [BigDecimal('1234.50'), BigDecimal('1234.50')], order.equipment_items.where(product: @product).pluck(:unit_cost)
      assert_nil order.equipment_items.find_by!(product: unknown.product).unit_cost
      assert_nil order.sent_at
      assert_equal order.id, bid.reload.purchase_order_id
      take_screenshot('bid-award-vendor-prices-recorded', html: true, full: true)
    ensure
      page.current_window.resize_to(1200, 800)
    end

    test 'purchasing histories show who changed needs bids and POs and retain those changes on the application' do
      application = equipment_application
      need = create(:equipment_need, application: application, product: @product)
      editor = create(:admin, first_name: 'Morgan', last_name: 'Purchasing')
      system_test_sign_in(@admin, bypass_mfa_enrollment: true)
      visit edit_admin_application_equipment_needs_path(application)
      fill_in 'equipment-need-quantity-0', with: '2'
      fill_in 'Reason for adjustment', with: 'Confirmed two devices are needed'
      click_button 'Save purchasing needs'
      assert_text 'Purchasing needs updated.'
      visit edit_admin_application_equipment_needs_path(application)
      within('#purchasing-needs-history') do
        assert_text "Purchasing needs updated — #{@admin.full_name}"
        assert_text 'Confirmed two devices are needed'
        assert_selector 'time[datetime]'
      end
      take_screenshot('purchasing-needs-actor-history', html: true, full: true)

      bid = Equipment::Bidding.new(actor: @admin).create!(number: 'HISTORY-BID', needs: [need_row(need.reload).merge(quantity: 2)])
      system_test_switch_user(editor, bypass_mfa_enrollment: true)
      visit admin_bid_group_path(bid)
      within('#bid-history') { assert_text "Bid created — #{@admin.full_name}" }
      fill_in "line-quantity-#{bid.active_lines.sole.id}", with: '1'
      fill_in 'Reason for change', with: 'The revised quote covers one device'
      click_button 'Save quantities'
      within('#bid-history') do
        assert_text "Bid updated — #{editor.full_name}"
        assert_text 'The revised quote covers one device'
        assert_text '2 devices'
        assert_text '1 device'
      end
      take_screenshot('bid-created-and-edited-history', html: true, full: true)
      click_link 'Enter PO details for this bid'
      fill_in 'New PO number', with: 'HISTORY-PO'
      fill_in 'Vendor name', with: 'First Vendor'
      fill_in "line-unit-cost-#{bid.active_lines.sole.id}", with: '100'
      click_button 'Save PO details'
      assert_text 'Purchase order HISTORY-PO'
      within('#purchase-order-history') { assert_text "PO recorded — #{editor.full_name}" }
      fill_in 'Supplier name', with: 'Corrected Vendor'
      fill_in 'Price paid (USD)', with: '125.50'
      click_button 'Save device costs'
      assert_text 'Actual device purchase costs saved.'
      within('#purchase-order-history') do
        assert_text "Vendor updated — #{editor.full_name}"
        assert_selector 'tbody tr', text: /Supplier name\s+First Vendor\s+Corrected Vendor/
        assert_selector 'tbody tr', text: /Price per device\s+\$100.00\s+\$125.50/
        assert_selector 'time[datetime]'
      end
      take_screenshot('purchase-order-created-and-edited-history', html: true, full: true)
      page.current_window.resize_to(390, 844)
      take_screenshot('purchase-order-actor-history-narrow', html: true, full: true)
      assert_operator page.evaluate_script('document.documentElement.scrollWidth'), :<=, 390

      page.current_window.resize_to(1200, 800)
      visit admin_application_path(application)
      within('#audit-logs') do
        assert_text 'Confirmed two devices are needed'
        assert_text 'The revised quote covers one device'
        assert_selector 'tbody tr', text: /Supplier name\s+First Vendor\s+Corrected Vendor/
        assert_selector 'tbody tr', text: /Price per device\s+\$100.00\s+\$125.50/
        assert_text @admin.full_name
        assert_text editor.full_name
      end
      take_screenshot('application-purchasing-activity-history', html: true, full: true)
    ensure
      page.current_window.resize_to(1200, 800)
    end

    test 'staff record delivery from shipment history and can retry an invalid date' do
      item = create(:equipment_item, product: @product, shipped_at: Date.current, tracking_number: 'PENDING-DELIVERY')
      system_test_sign_in(@admin, bypass_mfa_enrollment: true)
      visit admin_equipment_index_path(tab: 'shipped', application_id: item.application_id)
      click_link 'Awaiting delivery'
      within("#equipment-item-#{item.id}") do
        find('summary', text: 'Record delivery').click
        fill_in 'Date received', with: Date.yesterday.strftime('%m/%d/%Y')
        click_button 'Save delivery'
        assert_selector 'p[role=alert]', text: /cannot precede shipment/
        assert_field 'Date received', with: Date.yesterday.strftime('%m/%d/%Y')
        take_screenshot('awaiting-delivery-retry', html: true, full: true)
        fill_in 'Date received', with: Date.current.strftime('%m/%d/%Y')
        click_button 'Save delivery'
      end
      assert_text 'Delivery recorded.'
      assert_no_selector "#equipment-item-#{item.id}"
      click_link 'All shipments'
      assert_selector "#equipment-item-#{item.id} dt", exact_text: 'Date received'
      assert_equal Date.current, item.reload.delivered_on
      take_screenshot('shipment-history-delivered', html: true, full: true)
    end

    test 'equipment index pages return to applications and the dashboard' do
      sign_in(@admin, bypass_mfa_enrollment: true)
      paths = {
        'needs-fulfillment' => admin_equipment_index_path(tab: 'needs_ordering'),
        'awaiting-shipment' => admin_equipment_index_path(tab: 'ordered'),
        'shipment-history' => admin_equipment_index_path(tab: 'shipped'),
        'bids' => admin_bid_groups_path,
        'stock' => admin_stock_index_path,
        'purchase-orders' => admin_purchase_orders_path
      }
      paths.each do |name, path|
        visit path
        within('nav[aria-label="Equipment sections"]') do
          assert_selector 'article', count: 3
          assert_link 'Needs bid number', href: admin_equipment_index_path(tab: 'needs_ordering')
          assert_link 'Enter PO details', href: admin_bid_groups_path
          assert_link 'Stock', href: admin_stock_index_path
          assert_text 'device requests to fulfill'
          assert_text 'devices awaiting shipment'
          assert_text 'bids awaiting award'
          assert_text 'purchase orders missing a sent date'
        end
        within('nav[aria-label="Return navigation"]') do
          assert_link 'Back to Dashboard', href: admin_dashboard_path
          assert_link 'Back to Applications', href: admin_applications_path
        end
        take_screenshot("#{name}-return-navigation", html: true, full: true)
        next unless name.in?(%w[needs-fulfillment bids])

        page.current_window.resize_to(390, 844)
        assert_operator page.evaluate_script('document.documentElement.scrollWidth'), :<=, 390
        take_screenshot("#{name}-grouped-navigation-narrow", html: true, full: true)
        page.current_window.resize_to(1200, 800)
      end
      within('nav[aria-label="Equipment sections"]') { click_link 'Needs bid number' }
      assert_current_path admin_equipment_index_path(tab: 'needs_ordering')
      getting_bids = find('nav[aria-label="Equipment sections"] a', text: 'Needs bid number', exact_text: true)
      getting_bids.execute_script('this.focus()')
      assert_selector 'nav[aria-label="Equipment sections"] a:focus', text: 'Needs bid number'
      page.driver.browser.keyboard.type(:Tab)
      assert_selector "nav[aria-label='Equipment sections'] a[href='#{admin_bid_groups_path}']:focus"
      take_screenshot('equipment-section-keyboard-focus', html: true, full: true)
      within('nav[aria-label="Needs bid number views"]') { click_link 'Enter shipping info' }
      assert_current_path admin_equipment_index_path(tab: 'ordered')
      within('nav[aria-label="Needs bid number views"]') { click_link 'View shipment history' }
      assert_current_path admin_equipment_index_path(tab: 'shipped')
      within('nav[aria-label="Equipment sections"]') { click_link 'Enter PO details' }
      assert_current_path admin_bid_groups_path
      within('nav[aria-label="Enter PO details views"]') { click_link 'Purchase Orders' }
      assert_current_path admin_purchase_orders_path
      within('nav[aria-label="Equipment sections"]') { click_link 'Stock' }
      assert_current_path admin_stock_index_path
      assert_no_selector 'nav[aria-label="Needs bid number views"], nav[aria-label="Enter PO details views"]'
      click_link 'Back to Applications'
      assert_current_path admin_applications_path
      assert_selector '#page-title', text: 'Applications'
      assert_no_link 'Back to Applications'
      take_screenshot('applications-dashboard-return-navigation', html: true, full: true)
      click_link 'Back to Dashboard'
      assert_current_path admin_dashboard_path
      assert_no_selector 'nav[aria-label="Equipment and program tools"]'
      within('section[aria-labelledby="equipment-tools-heading"]') do
        assert_link 'Equipment', href: admin_equipment_index_path
        assert_link 'iCanConnect filing preparation', href: admin_icanconnect_filing_prep_path
      end
      within('section[aria-labelledby="configuration-tools-heading"]') do
        assert_link 'Manage Products', href: admin_products_path
        assert_link 'Feature Flags', href: admin_feature_flags_path
      end
      take_screenshot('dashboard-equipment-and-program-links', html: true, full: true)
    ensure
      page.current_window.resize_to(1200, 800)
    end

    test 'Enter filters the queue without starting a bid and matching group selection retains hidden selections' do
      samuel = equipment_application
      samuel.user.update!(first_name: 'Samuel', last_name: 'FilterProbe')
      aisha = equipment_application
      aisha.user.update!(first_name: 'Aisha', last_name: 'FilterProbe')
      first = create(:equipment_need, application: samuel, product: @product)
      second = create(:equipment_need, application: aisha, product: @product)
      system_test_sign_in(@admin, bypass_mfa_enrollment: true)
      visit admin_equipment_index_path
      check "equipment-row-EquipmentNeed-#{first.id}"
      fill_in 'Constituent name or application #', with: 'Aisha FilterProbe'
      find_field('Constituent name or application #').send_keys(:enter)
      assert_equal admin_equipment_index_path, URI.parse(current_url).path
      assert_text '1 selected (1 hidden by filters) · 1 unit'
      assert_checked_field "equipment-row-EquipmentNeed-#{first.id}", visible: :all
      group = find('[data-equipment-selection-target="group"]', text: @product.catalog_label)
      within(group) { check 'Select matching requests for this model' }
      assert_checked_field "equipment-row-EquipmentNeed-#{second.id}"
      assert_text '2 selected (1 hidden by filters) · 2 units'
      take_screenshot('equipment-filter-enter-preserves-selection', html: true, full: true)
      click_button 'Enter bid number'
      assert_equal new_admin_bid_group_path, URI.parse(current_url).path
      assert_text samuel.user.full_name
      assert_text aisha.user.full_name
      assert_includes URI.decode_www_form(URI.parse(current_url).query).to_h.values, 'Aisha FilterProbe'
    end

    test 'shipment filters stay in the queue and shipment history has no batch selection controls' do
      application = equipment_application
      application.user.update!(first_name: 'Receipt', last_name: 'FilterProbe')
      vendor_item = create(:equipment_item, application: application, product: @product)
      stock_item = create(:equipment_item, application: application, product: @product, fulfillment_source: 'existing_stock', purchase_order: nil,
                                           stock_received_on: Date.current, stock_allocated_at: Time.current, intake_provenance: 'Verified stock')
      item = create(:equipment_item, application: application, product: @product, shipped_at: Date.current,
                                     delivered_on: Date.current, tracking_number: 'RECORDED-SHIPMENT')
      system_test_sign_in(@admin, bypass_mfa_enrollment: true)
      visit admin_equipment_index_path(tab: 'ordered', source: 'stock')
      assert_selector "#equipment-row-EquipmentItem-#{stock_item.id}"
      assert_no_selector "#equipment-row-EquipmentItem-#{vendor_item.id}", visible: true
      select 'All sources', from: 'Equipment source'
      assert_selector "#equipment-row-EquipmentItem-#{vendor_item.id}"
      fill_in 'Constituent name or application #', with: application.user.full_name
      find_field('Constituent name or application #').send_keys(:enter)
      assert_equal admin_equipment_index_path, URI.parse(current_url).path
      assert_text 'Enter shipping info'
      assert_text 'Funding: MAT'
      assert_text 'Date received: Not recorded'
      take_screenshot('awaiting-shipment-funding-and-receipt-link', html: true, full: true)
      visit admin_equipment_index_path(tab: 'shipped')
      fill_in 'Constituent name or application #', with: application.user.full_name
      find_field('Constituent name or application #').send_keys(:enter)
      assert_equal admin_equipment_index_path, URI.parse(current_url).path
      assert_no_selector '#equipment-selection-form, [data-equipment-selection-target="rowCheckbox"], [data-equipment-selection-target="summary"]'
      assert_no_button 'Select matching'
      assert_selector 'dl dd', exact_text: 'MAT'
      assert_selector 'dl dd', exact_text: ApplicationController.helpers.accessible_date_value(item.delivered_on)
      assert_link 'Edit costs and receipt dates', href: edit_admin_icanconnect_financial_record_path("EquipmentItem:#{item.id}")
      take_screenshot('shipment-history-read-only-receipt-dates', html: true, full: true)
    end

    test 'an unsent PO separates product shipping details from device records and offers plain text' do
      @product.update!(msrp: '199.95')
      application = equipment_application
      need = create(:equipment_need, application:, product: @product, disability_setup_group: 'deaf')
      group = Equipment::Bidding.new(actor: @admin).create!(number: 'VISIBLE-BID', needs: [need_row(need)])
      order = award(group, number: 'VISIBLE-PO')
      sign_in(@admin, bypass_mfa_enrollment: true)
      visit admin_purchase_order_path(order)
      assert_text 'PO sent date needed'
      assert_no_text 'PO sent date needed · PO sent date needed'
      assert_text '101 Confirmed Street'
      assert_text 'Apartment 7'
      assert_text 'Care of Confirmed Guardian'
      assert_text 'MSRP $199.95'
      assert_field 'Price paid (USD)', with: ''
      unit = order.equipment_items.sole
      assert_selector "input#unit-cost-#{unit.id}[aria-describedby=cost-msrp-#{unit.id}]"
      fill_in 'Price paid (USD)', with: '149.50'
      click_button 'Save device costs'
      assert_text 'Actual device purchase costs saved.'
      assert_equal BigDecimal('149.50'), order.equipment_items.sole.unit_cost
      take_screenshot('po-msrp-and-actual-unit-cost', html: true, full: true)
      assert_selector 'h2', text: 'Supplier order list'
      assert_text 'Share this list with the vendor, along with any setup instructions they agreed to follow.'
      assert_selector 'h2', text: 'Device tracking and records'
      item = order.equipment_items.sole
      within("#equipment-item-#{item.id}") { find('summary', text: 'View tracking and actions', exact_text: true).click }
      within('#purchase-order-device-records') do
        assert_link "Application ##{application.id}"
        assert_no_selector 'dt', exact_text: 'Serial number'
        assert_no_selector 'dt', exact_text: 'IMEI'
        assert_text 'Funding'
        assert_no_text '101 Confirmed Street'
        assert_no_text 'Apartment 7'
        assert_no_selector 'input'
        assert_link 'Edit price and receipt dates', href: edit_admin_icanconnect_financial_record_path("EquipmentItem:#{item.id}")
        assert_link 'Correct device or shipping details', href: edit_admin_equipment_item_path(item)
      end
      assert_link 'Edit PO invoice and charges', href: edit_admin_icanconnect_financial_record_path("PurchaseOrder:#{order.id}")
      assert_no_selector '#supplier-list-text', visible: true
      find('summary', text: 'Copy plain text list of all products in this PO').click
      supplier_copy = "Purchase order VISIBLE-PO\n\n#{item.product.catalog_label}\nQuantity: 1\nShip to: #{application.user.full_name}\n" \
                      "Care of Confirmed Guardian\n101 Confirmed Street\nApartment 7\nBaltimore, MD, 21201"
      assert_field 'Supplier order list', with: supplier_copy
      assert_selector '#supplier-list-text[readonly]'
      assert_no_selector 'th', text: 'Disability setup'
      assert_selector 'table[aria-labelledby="supplier-list-heading"] th[scope=col]', text: 'Ship to'
      assert_selector 'table[aria-labelledby="supplier-list-heading"] td br'
      assert_no_match(/Deaf|Disability setup/, find_field('Supplier order list').value)
      take_screenshot('unsent-po-full-address-and-plain-text', html: true, full: true)
      page.current_window.resize_to(390, 844)
      take_screenshot('unsent-po-plain-text-narrow', html: true, full: true)
      assert_operator page.evaluate_script('document.documentElement.scrollWidth'), :<=, 390
      plain_text = find_field('Supplier order list')
      plain_text.execute_script("this.scrollIntoView({block: 'center'})")
      plain_text.click
      assert_field 'Supplier order list', with: supplier_copy
      region = find('[role="region"][aria-labelledby="supplier-list-heading"]')
      assert region.evaluate_script('this.scrollWidth <= this.clientWidth')
      find('summary', text: 'Copy plain text list of all products in this PO').execute_script('this.focus()')
      page.driver.browser.keyboard.type(:tab)
      assert_selector '#supplier-list-text:focus'
      page.current_window.resize_to(1200, 800)
      click_link 'Edit PO invoice and charges'
      assert_field 'Invoice total'
      assert_field 'Shipping cost'
      assert_field 'Tax cost'
      assert_field 'Invoice or timesheet (PDF)'
      take_screenshot('po-invoice-shipping-and-tax', html: true, full: true)
      click_link 'View purchase order details'
      assert_current_path admin_purchase_order_path(order)
      within("#equipment-item-#{item.id}") { find('summary', text: 'View tracking and actions', exact_text: true).click }
      within("#equipment-item-#{item.id}") { click_link 'Edit price and receipt dates' }
      assert_field 'Price paid for this device'
      assert_field 'Date received by the recipient'
      assert_field 'Installation date'
      visit admin_purchase_order_path(order)
      within("#equipment-item-#{item.id}") { find('summary', text: 'View tracking and actions', exact_text: true).click }
      within("#equipment-item-#{item.id}") { click_link 'Correct device or shipping details' }
      assert_field 'Device model'
      assert_field 'Correction reason'
    ensure
      page.current_window.resize_to(1200, 800)
    end

    test 'clear fulfillment rows lead through stock review into awaiting shipment' do
      @product.update!(manufacturer: 'Apple', model_number: 'iPad mini')
      application = equipment_application
      application.user.update!(first_name: 'Samuel', last_name: 'Reed')
      need = create(:equipment_need, application: application, product: @product, remaining_quantity: 3, unfulfilled_since: 37.days.ago)
      iphone = create(:product, manufacturer: 'Apple', name: 'iPhone navigation demo', model_number: 'iPhone navigation demo', device_types: ['Smartphone'])
      percy = equipment_application(user: create(:constituent, first_name: 'Percy', last_name: 'Jackson'))
      bid_need = create(:equipment_need, application: percy, product: iphone)
      bid = nil
      travel_to 4.weeks.ago do
        bid = Equipment::Bidding.new(actor: @admin).create!(number: 'OLDEST-NAV-BID', needs: [need_row(bid_need)])
      end
      theo = equipment_application(user: create(:constituent, first_name: 'Theo', last_name: 'Martin', mobility_disability: true),
                                   program_disability_groups: ['mobility'])
      order = nil
      travel_to 3.weeks.ago do
        order = create(:purchase_order, number: 'OLDEST-NAV-PO', sent_at: nil)
        create(:equipment_item, application: theo, product: iphone, purchase_order: order, disability_setup_group: 'mobility', po_assigned_at: Time.current)
      end
      all_product = create(:product, name: 'Fully stocked device')
      all_need = create(:equipment_need, product: all_product)
      no_stock_need = create(:equipment_need)
      stock = Equipment::StockReceipt.new(actor: @admin).existing!(product: @product, quantity: 2, received_on: Date.current, provenance: 'Verified shelf stock')
      Equipment::StockReceipt.new(actor: @admin).existing!(product: all_product, quantity: 1, received_on: Date.current, provenance: 'Verified shelf stock')
      system_test_sign_in(@admin, bypass_mfa_enrollment: true)
      visit admin_equipment_index_path
      within('nav[aria-label="Equipment sections"] article', text: 'Needs bid number') do
        assert_text 'Longest wait: 5 weeks'
        assert_link 'Samuel Reed', href: admin_equipment_index_path(tab: 'needs_ordering', application_id: application.id)
        within(find_link('Samuel Reed').find(:xpath, '..')) { assert_text '— Deaf iPad' }
      end
      within('nav[aria-label="Equipment sections"] article', text: 'Enter PO details') do
        assert_text 'Longest wait: 4 weeks'
        assert_link 'Percy Jackson', href: new_admin_purchase_order_path(bid_group_id: bid.id)
        within(find_link('Percy Jackson').find(:xpath, '..')) { assert_text '— Deaf iPhone' }
        assert_text 'Longest wait: 3 weeks'
        assert_link 'Theo Martin', href: admin_purchase_order_path(order)
        within(find_link('Theo Martin').find(:xpath, '..')) { assert_text '— Mobility iPhone' }
      end
      row = find("#equipment-row-EquipmentNeed-#{need.id}").find(:xpath, 'ancestor::tr')
      within(row) do
        assert_text 'Samuel Reed'
        assert_selector '[data-stock-coverage]', text: 'Partial'
        assert_text '101 Confirmed Street'
        assert_link 'Review equipment'
      end
      within(find("#equipment-row-EquipmentNeed-#{all_need.id}").find(:xpath, 'ancestor::tr')) { assert_selector '[data-stock-coverage]', text: 'All' }
      within(find("#equipment-row-EquipmentNeed-#{no_stock_need.id}").find(:xpath, 'ancestor::tr')) { assert_selector '[data-stock-coverage]', text: 'No' }
      within(find("#equipment-row-EquipmentNeed-#{bid_need.id}").find(:xpath, 'ancestor::tr')) do
        assert_selector '[data-stock-coverage]', text: 'No'
        assert_field "quantity-#{bid_need.id}", with: '0', disabled: true
        assert_selector 'input[type="checkbox"][disabled]'
      end
      assert_no_link text: /Stock:.*available/
      take_screenshot('fulfillment-clear-rows-stock-coverage', html: true, full: true)
      page.current_window.resize_to(390, 844)
      geometry = page.evaluate_script(<<~JS)
        Array.from(document.querySelectorAll('body *')).filter(element =>
          element.getBoundingClientRect().right > window.innerWidth &&
          (!element.closest('[role="region"]') || getComputedStyle(element).position === 'absolute')
        ).slice(0, 12).map(element => ({tag: element.tagName, classes: element.className,
          width: element.clientWidth, right: element.getBoundingClientRect().right}))
      JS
      assert_operator page.evaluate_script('document.documentElement.scrollWidth'), :<=, 390, geometry.inspect
      take_screenshot('fulfillment-navigation-and-rows-narrow', html: true, full: true)
      region = row.find(:xpath, 'ancestor::div[@role="region"]')
      24.times { region.send_keys(:right) }
      assert_operator region.evaluate_script('this.scrollLeft'), :>, 0
      take_screenshot('fulfillment-stock-and-address-columns-narrow', html: true, full: true)
      page.current_window.resize_to(1200, 800)
      fill_in 'Constituent name or application #', with: "##{application.id}"
      assert_text 'Samuel Reed'
      assert_no_selector "#equipment-row-EquipmentNeed-#{all_need.id}", visible: true
      fill_in 'Constituent name or application #', with: 'Samuel Reed'
      fill_in "quantity-#{need.id}", with: 2
      within(row) { assert_selector '[data-stock-coverage]', text: 'All' }
      take_screenshot('fulfillment-stock-quantity-selected', html: true, full: true)
      click_button 'Use stock'
      assert_text 'Reserve stock for dispatch'
      assert_field "allocate-#{need.id}", with: '2'
      assert_text '101 Confirmed Street'
      assert(stock.all? { |item| item.reload.application_id.nil? })
      take_screenshot('fulfillment-stock-review-before-reserving', html: true, full: true)
      click_button 'Reserve for dispatch'
      assert_text 'Stock reserved for dispatch.'
      assert_current_path admin_equipment_index_path(tab: 'ordered', source: 'stock', search: 'Samuel Reed')
      assert_equal 1, need.reload.remaining_quantity
      assert_equal :needs_fulfillment, application.reload.equipment_fulfillment_stage.stage
      assert_equal stock.map(&:id).sort, application.equipment_items.stock.pluck(:id).sort
      stock.each do |item|
        assert_equal application.shipping_snapshot, item.reload.shipping_snapshot
        assert_equal 'deaf', item.disability_setup_group
        assert_nil item.shipped_at
      end
      assert_link 'Enter shipping date and tracking'
      fill_in 'Constituent name or application #', with: 'No matching constituent'
      assert_text 'No equipment matches these filters.'
      fill_in 'Constituent name or application #', with: 'Samuel Reed'
      assert_link 'Enter shipping date and tracking'
      take_screenshot('fulfillment-stock-assigned-awaiting-shipment', html: true, full: true)
      click_link 'Enter shipping date and tracking'
      assert_selector 'h1', text: 'Enter shipping info'
      assert_field 'Date shipped'
      assert_field 'Tracking number'
      assert_field 'Carrier'
      assert_link 'Back to equipment queue'
      take_screenshot('shipping-info-form-from-queue', html: true, full: true)
      page.current_window.resize_to(390, 844)
      assert_operator page.evaluate_script('document.documentElement.scrollWidth'), :<=, 390
      take_screenshot('shipping-info-form-from-queue-narrow', html: true, full: true)
    ensure
      page.current_window.resize_to(1200, 800)
    end

    test 'stock purchasing keeps separate setup batches for one model through bid review and the PO' do
      @product.update!(manufacturer: 'Apple', name: 'Apple iPhone Pro Max with a long catalog model description',
                       model_number: 'iPhone Pro Max with a long catalog model description')
      create(:product, name: 'Unselected stock device')
      sign_in(@admin, bypass_mfa_enrollment: true)
      visit admin_stock_index_path
      click_link 'Create a bid to buy stock'
      within(find("#stock-quantity-#{@product.id}-0").find(:xpath, 'ancestor::td')) do
        fill_in 'Quantity', with: '10'
        select 'Deaf', from: 'Disability group'
        click_button "Add another setup for #{@product.name}"
        assert_equal "stock-quantity-#{@product.id}-1", page.evaluate_script('document.activeElement.id')
        fill_in "stock-quantity-#{@product.id}-1", with: '10'
        select 'DeafBlind', from: "stock-setup-#{@product.id}-1"
      end
      take_screenshot('stock-columns-and-two-setup-batches', html: true, full: true)
      page.current_window.resize_to(390, 844)
      assert_operator page.evaluate_script('document.documentElement.scrollWidth'), :<=, 390
      take_screenshot('stock-purchase-narrow-before-scroll', html: true, full: true)
      region = find('[role="region"][aria-label="Stock quantities and purchasing"]')
      assert region.evaluate_script('this.scrollWidth > this.clientWidth'), 'The stock table should overflow within its narrow region.'
      region.execute_script('this.focus()')
      assert_selector '[role="region"][aria-label="Stock quantities and purchasing"]:focus'
      page.driver.browser.keyboard.type(*Array.new(30, :right))
      assert_selector '[role="region"][aria-label="Stock quantities and purchasing"]' do |element|
        element.evaluate_script('this.scrollLeft > 0 && this.scrollLeft >= this.scrollWidth - this.clientWidth - 1')
      end
      take_screenshot('stock-purchase-narrow-setup-controls', html: true, full: true)
      page.current_window.resize_to(1200, 800)
      click_button 'Review stock bid'
      assert_selector 'p', text: /10 units.*Disability group: Deaf\z/
      assert_selector 'p', text: /10 units.*Disability group: DeafBlind\z/
      take_screenshot('stock-bid-review-two-setups', html: true, full: true)
      click_button 'Reserve selected products under this bid'
      assert_text "Number can't be blank"
      assert_selector 'p', text: /10 units.*Disability group: Deaf\z/
      assert_selector 'p', text: /10 units.*Disability group: DeafBlind\z/
      take_screenshot('stock-bid-number-retry-retains-setups', html: true, full: true)
      fill_in 'Bid number', with: 'TWO-STOCK-SETUPS'
      click_button 'Reserve selected products under this bid'
      assert_text 'Bid reserved.'
      assert_selector 'h2', text: @product.catalog_label, count: 2
      assert_selector 'dt', text: 'Destination:', count: 2
      assert_selector 'dd', text: 'Stock', count: 2
      assert_selector 'dd', exact_text: '10 Deaf'
      assert_selector 'dd', exact_text: '10 DeafBlind'
      assert_link 'Back to Dashboard', href: admin_dashboard_path
      assert_link 'Back to Applications', href: admin_applications_path
      group = BidGroup.find_by!(number: 'TWO-STOCK-SETUPS')
      assert_equal [['deaf', 10], ['deafblind', 10]], group.active_lines.order(:id).pluck(:supplier_setup_group, :quantity)
      take_screenshot('stock-bid-saved-two-setups', html: true, full: true)
      click_link 'Enter PO details for this bid'
      fill_in 'New PO number', with: 'TWO-SETUPS-PO'
      receiving_address.each { |field, value| fill_in "purchase_order_#{field}", with: value }
      click_button 'Save PO details'
      assert_text 'Award and unsent PO recorded.'
      order = PurchaseOrder.find_by!(number: 'TWO-SETUPS-PO')
      assert_equal 20, order.equipment_items.count
      copy = Equipment::SupplierList.new(purchase_order: order).plain_text
      assert_includes copy, "Quantity: 20\nShip to: Program stock\n"
      assert_not_includes copy, 'Deaf'
      take_screenshot('stock-purchase-order-two-setups', html: true, full: true)
      Equipment::Ordering.new(actor: @admin).mark_sent!(order:, sent_at: Date.current, expected_version: order.lock_version)
      visit admin_purchase_order_path(order)
      click_link 'Receive into stock'
      blind_line = group.active_lines.find_by!(supplier_setup_group: 'deafblind')
      blind_batch = blind_line.acquired_items.first.stock_receipt_batch
      assert_text 'Deaf · Bid TWO-STOCK-SETUPS'
      assert_text 'DeafBlind · Bid TWO-STOCK-SETUPS'
      fill_in "receive-#{blind_batch}", with: '1'
      fill_in "receive-serial-#{blind_batch}-0", with: 'SECOND-SETUP-FIRST'
      take_screenshot('stock-receipt-two-configurations', html: true, full: true)
      click_button 'Receive 1 unit into stock'
      assert_text 'Stock receipt recorded.'
      received = order.equipment_items.where.not(stock_received_on: nil).sole
      assert_equal blind_line.id, received.acquisition_bid_group_line_id
      assert_equal 'SECOND-SETUP-FIRST', received.serial_number
    ensure
      page.current_window.resize_to(1200, 800)
    end

    test 'stock receipt starts at zero and preserves attempted quantities on a concurrent retry' do
      group = Equipment::Bidding.new(actor: @admin).create!(number: 'RECEIVE-BID', purpose: 'program_stock', stock: [{ product_id: @product.id, quantity: 4 }])
      order = award(group, number: 'RECEIVE-PO', **receiving_address)
      Equipment::Ordering.new(actor: @admin).mark_sent!(order:, sent_at: 2.days.ago.to_date, expected_version: order.lock_version)
      batch = order.equipment_items.order(:id).first.stock_receipt_batch
      quantity_field = "receive-#{batch}"
      sign_in(@admin, bypass_mfa_enrollment: true)
      visit admin_stock_index_path
      click_link 'Receive PO RECEIVE-PO'
      click_link 'Receive into stock'
      assert_field quantity_field, with: '0'
      assert_button 'Receive 0 units into stock', disabled: true
      take_screenshot('stock-receipt-zero-default', html: true, full: true)
      fill_in quantity_field, with: '3'
      fill_in 'Device 1 serial number (optional)', with: 'RETRY-SERIAL'
      fill_in 'Device 3 serial number (optional)', with: 'TRAILING-DRAFT'
      fill_in "receive-imei-#{batch}-0", with: '123456789012345'
      # A second administrator receives two units while this review is open.
      Equipment::StockReceipt.new(actor: @admin).receive!(order:, received_on: Date.current,
                                                          rows: [{ batch: batch, quantity: 2 }], expected_version: order.lock_version,
                                                          item_versions: order.equipment_items.active.where(stock_received_on: nil).to_h { |item| [item.id.to_s, item.lock_version.to_s] })
      click_button 'Receive 3 units into stock'
      assert_text 'Outstanding stock changed'
      assert_text 'The counts below are up to date. We kept your entries. Check them before saving again.'
      assert_field quantity_field, with: '3'
      assert_field 'Device 1 serial number (optional)', with: 'RETRY-SERIAL'
      assert_field 'Device 3 serial number (optional)', with: 'TRAILING-DRAFT'
      assert_field "receive-imei-#{batch}-0", with: '123456789012345'
      take_screenshot('stock-receipt-concurrent-retry', html: true, full: true)
      fill_in quantity_field, with: '1'
      assert_no_selector "#receive-serial-#{batch}-2", visible: true
      fill_in quantity_field, with: '3'
      assert_field 'Device 3 serial number (optional)', with: 'TRAILING-DRAFT'
      fill_in quantity_field, with: '1'
      fill_in 'Device 1 serial number (optional)', with: 'CONFIRMED-RETRY-SERIAL'
      fill_in "receive-imei-#{batch}-0", with: '234567890123456'
      fill_in 'Received on', with: '02/30/2026'
      click_button 'Receive 1 unit into stock'
      assert_text 'Enter an actual received date.'
      assert_field 'Received on', with: '02/30/2026'
      assert_field 'Device 1 serial number (optional)', with: 'CONFIRMED-RETRY-SERIAL'
      take_screenshot('stock-receipt-invalid-date-retry', html: true, full: true)
      fill_in 'Received on', with: 1.day.ago.to_date.strftime('%m/%d/%Y')
      click_button 'Receive 1 unit into stock'
      assert_text '3 received'
      assert_text '1 outstanding'
      assert_equal 1.day.ago.to_date, order.equipment_items.find_by!(normalized_serial_number: 'CONFIRMED-RETRY-SERIAL').stock_received_on
      take_screenshot('stock-receipt-partial-result', html: true, full: true)
      click_link 'Receive into stock'
      click_button 'Receive remaining'
      assert_field quantity_field, with: '1'
      click_button 'Receive 1 unit into stock'
      assert_text '4 received'
      assert_text '0 outstanding'
      assert_no_link 'Receive into stock'
      take_screenshot('stock-receipt-complete-result', html: true, full: true)
    end

    test 'allocated stock moves through packing to guardian-visible equipment guidance' do
      guardian = create(:constituent)
      dependent = create(:constituent)
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent)
      application = equipment_application(user: dependent, managing_guardian: guardian)
      need = create(:equipment_need, application:, product: @product, disability_setup_group: 'deaf')
      Equipment::StockReceipt.new(actor: @admin).existing!(product: @product, quantity: 1, received_on: 2.days.ago.to_date,
                                                           provenance: 'Verified shelf stock')
      create(:product_resource, product: @product, title: 'Exact tablet setup guide')
      sign_in(@admin, bypass_mfa_enrollment: true)
      visit new_admin_stock_allocation_path(need_ids: [need.id], quantities: { need.id.to_s => 1 })
      assert_text '101 Confirmed Street'
      application.update!(shipping_address_1: '202 Updated Confirmed Street')
      click_button 'Reserve for dispatch'
      assert_text 'Application details changed'
      assert_field 'Quantity', with: '1'
      take_screenshot('allocation-stale-profile-draft', html: true, full: true)
      click_button 'Refresh address and setup (keep changes)'
      assert_text 'The shipping address and device setup have been refreshed.'
      assert_text '202 Updated Confirmed Street'
      assert_field 'Quantity', with: '1'
      take_screenshot('allocation-explicit-profile-refresh', html: true, full: true)
      click_button 'Reserve for dispatch'
      assert_text 'Stock reserved for dispatch.'
      item = application.equipment_items.sole
      take_screenshot('stock-reserved-grouped-dispatch-queue', html: true, full: true)
      system_test_switch_user(guardian)
      visit constituent_portal_dashboard_path
      assert_text "Devices for #{dependent.full_name}"
      assert_text 'Preparing shipment from stock'
      take_screenshot('guardian-dashboard-preparing-stock', html: true, full: true)
      click_link @product.name, match: :first
      assert_text 'Exact tablet setup guide'
      take_screenshot('guardian-guidance-before-stock-dispatch', html: true, full: true)
      system_test_switch_user(@admin, bypass_mfa_enrollment: true)
      visit new_admin_equipment_shipment_path(item_ids: [item.id])
      assert_text 'Setup ordered for stock: Not recorded'
      assert_text 'Setup for this recipient: Deaf'
      assert_text 'Internal dispatch list'
      assert_field 'Serial number', with: ''
      assert_field 'IMEI', with: ''
      assert_no_text 'Identifier not recorded'
      take_screenshot('stock-packing-setup-and-identifier', html: true, full: true)
      fill_in "packing-#{item.id}-serial_number", with: 'PACKED-PHYSICAL-UNIT'
      fill_in "packing-#{item.id}-imei", with: '123'
      fill_in 'Date shipped', with: 1.day.ago.to_date.strftime('%m/%d/%Y')
      fill_in 'Tracking number', with: 'RETRY-TRACKING'
      check 'I checked the devices and confirmed they are set up for this recipient.'
      click_button 'Save shipping info'
      assert_text 'must contain 15 digits'
      assert_field "packing-#{item.id}-serial_number", with: 'PACKED-PHYSICAL-UNIT'
      assert_field "packing-#{item.id}-imei", with: '123'
      assert_field 'Date shipped', with: 1.day.ago.to_date.strftime('%m/%d/%Y')
      assert_field 'Tracking number', with: 'RETRY-TRACKING'
      assert_checked_field 'I checked the devices and confirmed they are set up for this recipient.'
      take_screenshot('stock-packing-validation-retry', html: true, full: true)
      fill_in "packing-#{item.id}-imei", with: '345678901234567'
      fill_in 'Date shipped', with: '02/30/2026'
      click_button 'Save shipping info'
      assert_text 'Enter an actual shipment date.'
      assert_field 'Date shipped', with: '02/30/2026'
      take_screenshot('stock-packing-invalid-date-retry', html: true, full: true)
      fill_in 'Date shipped', with: Date.current.strftime('%m/%d/%Y')
      fill_in 'Tracking number', with: 'ACTUAL-DISPATCH'
      select 'USPS', from: 'Carrier'
      uncheck 'I checked the devices and confirmed they are set up for this recipient.'
      click_button 'Save shipping info'
      assert_text 'Confirm the constituent setup before packing stock.'
      assert_unchecked_field 'I checked the devices and confirmed they are set up for this recipient.'
      check 'I checked the devices and confirmed they are set up for this recipient.'
      click_button 'Save shipping info'
      assert_text 'Outbound shipment recorded.'
      assert_equal 'PACKED-PHYSICAL-UNIT', item.reload.serial_number
      assert_equal Date.current, item.shipped_at
      assert_equal 'ACTUAL-DISPATCH', item.tracking_number
      assert_equal 'usps', item.carrier
      assert item.setup_confirmed_at
      take_screenshot('stock-dispatch-result', html: true, full: true)

      system_test_switch_user(guardian)
      visit constituent_portal_dashboard_path
      assert_text "Devices for #{dependent.full_name}"
      assert_text 'Shipped by the program'
      take_screenshot('guardian-dashboard-shipped-stock', html: true, full: true)
      click_link @product.name, match: :first
      assert_text 'Exact tablet setup guide'
      take_screenshot('guardian-device-guidance-after-stock-dispatch', html: true, full: true)
    end

    private

    def equipment_application(**attributes)
      create(:application, :approved, :with_all_proofs, fulfillment_type: :equipment,
                                                        equipment_needs_initialized_at: Time.current, program_disability_groups: ['deaf'],
                                                        shipping_care_of: 'Confirmed Guardian', shipping_address_1: '101 Confirmed Street', shipping_address_2: 'Apartment 7',
                                                        shipping_city: 'Baltimore', shipping_state: 'MD', shipping_zip_code: '21201', **attributes)
    end

    def receiving_address
      { shipping_address_1: '900 Receiving Road', shipping_address_2: 'Dock 3', shipping_city: 'Baltimore', shipping_state: 'MD', shipping_zip_code: '21201' }
    end

    def need_row(need)
      { id: need.id, quantity: 1, lock_version: need.lock_version }
    end

    def award(group, **attributes)
      Equipment::Ordering.new(actor: @admin).call(bid_group: group, application_versions: equipment_bid_profile_versions(group), expected_version: group.lock_version,
                                                  line_versions: group.active_lines.to_h { |line| [line.id.to_s, line.lock_version.to_s] }, purchase_order_attributes: attributes)
    end
  end
end
