# frozen_string_literal: true

require 'test_helper'

module Admin
  class EquipmentControllerTest < ActionDispatch::IntegrationTest
    include IcanconnectTestSupport

    setup do
      start_icanconnect!
      @admin = create(:admin)
      sign_in_for_integration_test(@admin, bypass_mfa_enrollment: true)
      @product = create(:product, name: 'Exact phone')
      @need = create(:equipment_need, product: @product, remaining_quantity: 2)
      @detached = create(:equipment_item, application: @need.application, product: @product, purchase_order: nil)
    end

    test 'filters target the equipment queue while a separate native form carries the selected requests' do
      get admin_equipment_index_path
      assert_response :success
      assert_select 'h1', text: 'Needs bid number'
      assert_select '[data-controller=equipment-selection]', count: 1
      assert_select 'form#equipment-filters[action=?][method=get]', admin_equipment_index_path
      assert_select 'form#equipment-selection-form[action=?][method=get]', new_admin_bid_group_path
      assert_select 'form form', count: 0
      assert_select 'input[name="need_ids[]"][value=?]', @need.id.to_s
      assert_select 'input[name="item_ids[]"][value=?]', @detached.id.to_s
      assert_select 'input[name=?][value="2"][disabled]', "quantities[#{@need.id}]"
      assert_select '[data-equipment-selection-target=programGroup]'
      assert_select '[data-equipment-selection-target=category]'
      assert_select 'select[name=vendor_id]', count: 0
      assert_select 'input[value="Enter bid number"]'
      assert_select 'label[for=equipment_search]', text: 'Constituent name or application #'
      ['Constituent name', 'Disability group', 'Quantity to fulfill', 'In stock?', 'Shipping destination', 'Review equipment'].each do |heading|
        assert_select 'th[scope=col]', text: heading
      end
      assert_includes response.body, @need.application.shipping_address_1
      assert_select 'td', text: 'Deaf'
    end

    test 'unavailable requested models remain visible for equipment review' do
      @product.archive!
      get admin_equipment_index_path
      assert_response :success
      assert_includes response.body, @product.catalog_label
      assert_select 'a[href=?]', edit_admin_application_equipment_needs_path(@need.application_id, return_context: { tab: 'needs_ordering' }), text: 'Review equipment'
    end

    test 'stock review requires and retains acknowledgement when replacing ICC devices with MAT stock' do
      application = approved_deafblind_application
      item = create(:equipment_item, application: application, product: @product, purchase_order: nil,
                                     funding_source: 'icanconnect', disability_setup_group: 'deafblind')
      get new_admin_stock_allocation_path(item_ids: [@detached.id])
      assert_select 'input[name="allocation[confirm_mat_funding]"]', count: 0
      get new_admin_stock_allocation_path(item_ids: [item.id])
      assert_select 'input[type=checkbox][name="allocation[confirm_mat_funding]"][required]:not([checked])'
      assert_select '#mat-stock-funding-help', text: /keep MAT funding/
      data = { items: [{ id: item.id, lock_version: item.lock_version }], confirm_mat_funding: '0' }
      profiles = equipment_profile_versions(application)
      post admin_stock_allocations_path, params: { allocation: data, application_versions: profiles }
      assert_response :unprocessable_content
      assert_select 'li', text: 'Confirm replacing the iCanConnect-funded devices with MAT stock.'
      assert_nil item.reload.withdrawn_at
      data[:confirm_mat_funding] = '1'
      post admin_stock_allocations_path, params: { allocation: data, application_versions: profiles }
      assert_response :unprocessable_content
      assert_select 'input[type=checkbox][name="allocation[confirm_mat_funding]"][checked]'
      stock = Equipment::StockReceipt.new(actor: @admin).existing!(product: @product, quantity: 1, received_on: Date.current, provenance: 'Verified stock').sole
      post admin_stock_allocations_path, params: { allocation: data, application_versions: profiles }
      assert_redirected_to admin_equipment_index_path(tab: 'ordered', source: 'stock')
      assert_equal application.id, stock.reload.application_id
      assert_equal 'mat', stock.funding_source
      assert_equal stock.id, item.reload.replaced_by_equipment_item_id
    end

    test 'awaiting shipment contains sent direct units and excludes unsent purchase orders' do
      sent = create(:equipment_item, product: @product)
      unsent = create(:equipment_item, purchase_order: create(:purchase_order, sent_at: nil))
      shipped = create(:equipment_item, product: @product, shipped_at: Date.current, delivered_on: Date.current, tracking_number: 'SHIPPED-TRACK')
      get admin_equipment_index_path(tab: 'ordered')
      assert_response :success
      assert_select "input[name='item_ids[]'][value='#{sent.id}']"
      assert_select "input[name='item_ids[]'][value='#{unsent.id}']", count: 0
      assert_select "input[name='item_ids[]'][value='#{shipped.id}']", count: 0
      assert_select '[data-equipment-selection-target=source]'
      assert_select 'form#equipment-selection-form[action=?]', new_admin_equipment_shipment_path
      assert_select 'a[href=?]', edit_admin_icanconnect_financial_record_path("EquipmentItem:#{sent.id}"), text: 'Costs and receipt dates'
      get admin_equipment_index_path(tab: 'shipped')
      assert_select 'form#equipment-filters[action=?]', admin_equipment_index_path
      assert_select '[data-equipment-selection-target=source]'
      assert_select 'form#equipment-selection-form, input[name="item_ids[]"], [data-equipment-selection-target=summary], [data-equipment-selection-target=groupCheckbox]', count: 0
      assert_select 'button', text: 'Select matching', count: 0
      assert_select 'a[href=?]', edit_admin_icanconnect_financial_record_path("EquipmentItem:#{shipped.id}"), text: 'Edit costs and receipt dates'
      assert_select 'dt', text: 'Funding'
      assert_select 'dd', text: 'MAT'
      assert_select 'dt', text: 'Date received'
      assert_select 'dd', text: ApplicationController.helpers.accessible_date_value(shipped.delivered_on)
      assert_select 'dl a[href=?]', admin_purchase_order_path(shipped.purchase_order), text: shipped.purchase_order.number
    end

    test 'packing a released reservation returns to the current shipping queue' do
      stock = Equipment::StockReceipt.new(actor: @admin).existing!(product: @product, quantity: 1, received_on: Date.current, provenance: 'Verified stock').sole
      allocation = Equipment::StockAllocation.new(actor: @admin)
      allocation.allocate!(needs: [{ id: @need.id, lock_version: @need.lock_version, quantity: 1 }],
                           application_versions: equipment_profile_versions(@need.application))
      get new_admin_equipment_shipment_path(item_ids: [stock.id])
      assert_response :success
      stale_version = stock.reload.lock_version
      allocation.release!(item: stock, expected_version: stale_version, reason: 'Returned to stock')

      post admin_equipment_shipments_path, params: {
        shipment: { shipped_at: Date.current.to_s, tracking_number: 'STALE', confirm_setup: '1',
                    rows: [{ id: stock.id, lock_version: stale_version }] }
      }
      assert_redirected_to admin_equipment_index_path(tab: 'ordered')
      assert_nil stock.reload.shipped_at
      assert_includes EquipmentItem.available_stock, stock
    end

    test 'a retried existing stock form reuses its intake and a fresh form starts a new intake' do
      get new_admin_stock_path
      operation_id = css_select('input[name="stock[operation_id]"]').sole['value']
      stock = { product_id: @product.id, quantity: 2, received_on: Date.current.to_s, provenance: 'Verified stock', operation_id: operation_id }
      assert_difference(-> { EquipmentItem.available_stock.where(product: @product).count }, 2) do
        2.times do
          post admin_stock_index_path, params: { stock: stock }
          assert_redirected_to admin_stock_index_path
        end
      end
      get new_admin_stock_path
      stock[:operation_id] = css_select('input[name="stock[operation_id]"]').sole['value']
      assert_not_equal operation_id, stock[:operation_id]
      assert_difference(-> { EquipmentItem.available_stock.where(product: @product).count }, 2) do
        post admin_stock_index_path, params: { stock: stock }
        assert_redirected_to admin_stock_index_path
      end
    end

    test 'vendor access cannot list operational equipment' do
      sign_in_for_integration_test(create(:vendor), bypass_mfa_enrollment: true)
      get admin_equipment_index_path
      assert_redirected_to root_path
    end

    test 'equipment index surfaces provide deterministic dashboard and applications return links' do
      pages = [
        [admin_equipment_index_path(tab: 'needs_ordering'), 'Needs bid number', 'Needs bid number views', 'Needs bid number', 3],
        [admin_equipment_index_path(tab: 'ordered'), 'Needs bid number', 'Needs bid number views', 'Enter shipping info', 3],
        [admin_equipment_index_path(tab: 'shipped'), 'Needs bid number', 'Needs bid number views', 'View shipment history', 3],
        [admin_bid_groups_path, 'Enter PO details', 'Enter PO details views', 'Bids', 2],
        [admin_purchase_orders_path, 'Enter PO details', 'Enter PO details views', 'Purchase Orders', 2],
        [admin_stock_index_path, 'Stock', nil, nil, 0]
      ]

      pages.each do |path, section, views_label, current_view, view_count|
        get path
        assert_response :success
        assert_equipment_sections(section)
        if views_label
          assert_select 'nav[aria-label=?]', views_label do
            assert_select 'a[data-turbo-frame="_top"]', count: view_count
            assert_select 'a[aria-current=page]', count: 1
            assert_select 'a[aria-current=page][href=?]', path, text: current_view
          end
        else
          assert_select 'nav[aria-label="Needs bid number views"], nav[aria-label="Enter PO details views"]', count: 0
        end
        assert_select 'nav[aria-label="Return navigation"]' do
          assert_select 'a.btn.btn-outline[href=?][data-turbo-frame="_top"]', admin_dashboard_path, text: 'Back to Dashboard'
          assert_select 'a.btn.btn-outline[href=?][data-turbo-frame="_top"]', admin_applications_path, text: 'Back to Applications'
        end
      end
      get admin_applications_path
      assert_response :success
      assert_select 'nav[aria-label="Equipment sections"]', count: 0
      assert_select 'nav[aria-label="Return navigation"]' do
        assert_select 'a[href=?]', admin_dashboard_path, text: 'Back to Dashboard'
        assert_select 'a', text: 'Back to Applications', count: 0
      end
    end

    test 'per request stock coverage distinguishes full partial empty and bid reserved quantities' do
      Equipment::StockReceipt.new(actor: @admin).existing!(product: @product, quantity: 2, received_on: Date.current, provenance: 'Verified shelf stock')
      partial = create(:equipment_need, product: @product, remaining_quantity: 3)
      empty = create(:equipment_need)
      reserved = create(:equipment_need, product: @product)
      reserved_empty = create(:equipment_need)
      Equipment::Bidding.new(actor: @admin).create!(number: 'RESERVED-NEED', needs: [reserved, reserved_empty].map do |need|
        { id: need.id, quantity: 1, lock_version: need.lock_version }
      end)

      get admin_equipment_index_path

      { @need => 'All', partial => 'Partial', empty => 'No', reserved => 'All', reserved_empty => 'No' }.each do |need, expected|
        row = css_select("input[name='need_ids[]'][value='#{need.id}']").sole.ancestors('tr').first
        assert_equal expected, row.at_css('[data-stock-coverage]').text
      end
      assert_select "input#equipment-row-EquipmentNeed-#{reserved.id}[disabled]"
      assert_select "input#equipment-row-EquipmentNeed-#{reserved_empty.id}[disabled]"
      assert_select "input#quantity-#{reserved.id}[value='0']"
      assert_select "input#quantity-#{reserved_empty.id}[value='0']"
      assert_select 'p', text: '1 device already in a bid'
      assert_select 'a', text: /Stock:.*available/, count: 0
      assert_no_match(/0 reserved under a bid/, response.body)
    end

    test 'equipment navigation retains its active section and view with nested filters' do
      get admin_equipment_index_path, params: { return_context: { tab: 'ordered', product_id: @product.id } }

      assert_equipment_sections('Needs bid number')
      assert_select 'nav[aria-label="Needs bid number views"] a[aria-current=page][href=?]', admin_equipment_index_path(tab: 'ordered'),
                    text: 'Enter shipping info'
    end

    test 'equipment summary names link to the oldest global request and shipment even on a filtered queue' do
      oldest_request = create(:equipment_need, product: create(:product, model_number: 'iPad Pro 13-inch'), unfulfilled_since: 3.weeks.ago)
      oldest_request.application.update!(program_disability_groups: ['low_vision_blind'])
      oldest_request.update!(disability_setup_group: 'low_vision_blind')
      oldest_shipment = create(:equipment_item, product: create(:product, model_number: 'iPhone 17 Pro Max'),
                                                purchase_order: create(:purchase_order, sent_at: 2.weeks.ago.to_date))

      get admin_equipment_index_path(application_id: @need.application_id, tab: 'needs_ordering')

      assert_response :success
      assert_select 'nav[aria-label="Equipment sections"] article:first-child' do
        assert_select 'p.text-xs.text-gray-600', text: /\A\s*Longest known wait:\s+3 weeks\s*\z/
        assert_select 'a[href=?][data-turbo-frame="_top"]',
                      admin_equipment_index_path(tab: 'needs_ordering', application_id: oldest_request.application_id),
                      text: oldest_request.application.user.full_name
        assert_select 'span', text: '— Low Vision / Blind iPad'
        assert_select 'p.text-xs.text-gray-600', text: /\A\s*Longest wait:\s+2 weeks\s*\z/
        assert_select 'a[href=?][data-turbo-frame="_top"]',
                      admin_equipment_index_path(tab: 'ordered', application_id: oldest_shipment.application_id),
                      text: oldest_shipment.application.user.full_name
        assert_select 'span', text: '— Deaf iPhone'
      end
    end

    test 'purchasing summary links the oldest bid and unsent PO to their next task with constituent and device context' do
      need = create(:equipment_need, product: create(:product, model_number: 'iPhone 17 Pro Max'))
      other = create(:equipment_need)
      bid = Equipment::Bidding.new(actor: @admin).create!(number: 'NAVIGATION-AWARD', needs: [need, other].map do |request|
        { id: request.id, quantity: 1, lock_version: request.lock_version }
      end)
      bid.update!(created_at: 4.weeks.ago)
      order = create(:purchase_order, sent_at: nil)
      item = create(:equipment_item, product: create(:product, model_number: 'iPad mini 7'), purchase_order: order, po_assigned_at: 3.weeks.ago)

      get admin_bid_groups_path

      assert_response :success
      assert_select 'nav[aria-label="Equipment sections"] article:nth-child(2)' do
        assert_select 'a[href=?][data-turbo-frame="_top"]', new_admin_purchase_order_path(bid_group_id: bid.id), text: need.application.user.full_name
        assert_select 'span', text: '— Deaf iPhone · + 1 other constituent'
        assert_select 'a[href=?][data-turbo-frame="_top"]', admin_purchase_order_path(order), text: item.application.user.full_name
        assert_select 'span', text: '— Deaf iPad'
      end
    end

    test 'equipment reports link to bids awaiting award' do
      awaiting_award = Equipment::Bidding.new(actor: @admin).create!(
        number: 'READY-BID', needs: [{ id: @need.id, quantity: 1, lock_version: @need.lock_version }]
      )
      unreserved = BidGroup.create!(number: 'UNRESERVED-BID', purpose: 'direct_to_constituents')
      filtered_path = admin_bid_groups_path(state: 'awaiting_award')

      get equipment_distribution_admin_reports_path

      assert_response :success
      assert_select 'a[href=?]', filtered_path, text: 'Bid groups awaiting award'

      get filtered_path

      assert_response :success
      assert_select 'article a[href=?]', admin_bid_group_path(awaiting_award)
      assert_select 'article a[href=?]', admin_bid_group_path(unreserved), count: 0
    end

    test 'empty batch reviews return to the filtered queue and stock reviews retain context' do
      context = { tab: 'needs_ordering', application_id: @need.application_id.to_s, search: 'Selected constituent', program_group: 'deaf' }
      [new_admin_bid_group_path, new_admin_stock_allocation_path].each do |path|
        get path, params: { return_context: context }
        assert_redirected_to admin_equipment_index_path(context)
      end
      ordered_context = context.merge(tab: 'ordered', source: 'vendor')
      get new_admin_equipment_shipment_path, params: { return_context: ordered_context }
      assert_redirected_to admin_equipment_index_path(ordered_context)
      get new_admin_bid_group_path, params: { stock: [{ product_id: @product.id, quantity: '0' }] }
      assert_redirected_to admin_stock_index_path

      get new_admin_stock_allocation_path, params: { need_ids: [@need.id], return_context: context }
      assert_response :success
      context.each { |key, value| assert_select 'input[type=hidden][name=?][value=?]', "return_context[#{key}]", value }
      assert_select 'a[href=?]', admin_equipment_index_path(context), text: 'Back to equipment queue'
    end

    test 'shipment dates accept MM DD YYYY and preserve unreadable input on retry' do
      item = create(:equipment_item, product: @product)
      context = { tab: 'ordered', application_id: item.application_id.to_s, source: 'vendor' }
      shipment = { shipped_at: '02/30/2026', tracking_number: 'DATE-RETRY', rows: [{ id: item.id, lock_version: item.lock_version }] }
      assert_no_enqueued_emails { post admin_equipment_shipments_path, params: { shipment: shipment, return_context: context } }
      assert_response :unprocessable_content
      assert_nil item.reload.shipped_at
      assert_select 'input[type=text][name="shipment[shipped_at]"][value="02/30/2026"]'
      assert_select 'a[href=?]', admin_equipment_index_path(context), text: 'Back to equipment queue'

      shipment[:shipped_at] = Date.current.strftime('%m/%d/%Y')
      mail = capture_emails { post admin_equipment_shipments_path, params: { shipment: shipment, return_context: context } }.sole
      assert_redirected_to admin_equipment_index_path(context.merge(tab: 'shipped'))
      assert_equal Date.current, item.reload.shipped_at
      assert_equal [item.application.user.email], mail.to
      assert_includes mail.text_part.body.decoded.lines.map(&:strip), 'Tracking number — DATE-RETRY'
      assert_nil Nokogiri::HTML(mail.html_part.body.decoded).at_css('a')
    end

    test 'a package recorded in separate saves sends one notice in the managing guardian’s language' do
      ensure_system_audit_actor!
      item = create(:equipment_item)
      application = item.application
      guardian = create(:constituent, locale: 'es')
      create(:guardian_relationship, guardian_user: create(:constituent), dependent_user: application.user)
      create(:guardian_relationship, guardian_user: guardian, dependent_user: application.user)
      application.user.update!(email: "dependent-#{SecureRandom.uuid}@system.matvulcan.local", dependent_email: guardian.email)
      application.update!(managing_guardian: guardian)
      sibling = create(:equipment_item, application: application)
      shipment = { shipped_at: Date.current.iso8601, tracking_number: 'GUARDIAN-PACKAGE', carrier: 'dhl' }
      notices = Notification.where(action: 'equipment_shipment_notice', notifiable: application)

      mail = capture_emails do
        [item, sibling].each do |unit|
          post admin_equipment_shipments_path, params: { shipment: shipment.merge(rows: [{ id: unit.id, lock_version: unit.lock_version }]) }
          assert_response :redirect
          assert_equal Date.current, unit.reload.shipped_at
        end
      end.sole

      assert_equal [guardian.email], mail.to
      assert_equal 'Su equipo de MAT está en camino', mail.subject
      assert_includes mail.text_part.body.decoded, "para #{application.user.first_name}"
      assert_includes mail.text_part.body.decoded.lines.map(&:strip), 'Número de seguimiento — GUARDIAN-PACKAGE (DHL)'
      assert_equal guardian.id, notices.sole.recipient_id
    end

    test 'a shipment without an email address is saved and the application history explains why no notice went out' do
      ensure_system_audit_actor!
      item = create(:equipment_item)
      application = item.application
      application.user.update!(email: "no-email-#{SecureRandom.uuid}@system.matvulcan.local", communication_preference: :letter)
      shipment = { shipped_at: Date.current.iso8601, tracking_number: 'NO-EMAIL', rows: [{ id: item.id, lock_version: item.lock_version }] }

      assert_no_enqueued_emails { post admin_equipment_shipments_path, params: { shipment: shipment } }
      assert_response :redirect
      assert_equal Date.current, item.reload.shipped_at

      get admin_application_path(application)
      assert_response :success
      assert_includes response.body, 'Not sent — no email address'
      assert_includes response.body, 'No usable email address is recorded.'
    end

    test 'existing stock keeps a rejected date and accepts a corrected typed date' do
      get new_admin_stock_path
      operation_id = css_select('input[name="stock[operation_id]"]').sole['value']
      data = { product_id: @product.id, quantity: 1, received_on: '02/30/2026', provenance: 'Verified shelf count', operation_id: operation_id }
      assert_no_difference 'EquipmentItem.count' do
        post admin_stock_index_path, params: { stock: data }
      end
      assert_response :unprocessable_content
      assert_select 'input[type=text][name="stock[received_on]"][value="02/30/2026"]'
      assert_select 'input[name="stock[operation_id]"][value=?]', operation_id
      data[:received_on] = Date.current.strftime('%m/%d/%Y')
      assert_difference 'EquipmentItem.count', 1 do
        post admin_stock_index_path, params: { stock: data }
      end
      assert_redirected_to admin_stock_index_path
      assert_equal Date.current, EquipmentItem.order(:id).last.stock_received_on
    end

    test 'stock purchasing names its columns and links to only open stock bids' do
      open_stock = Equipment::Bidding.new(actor: @admin).create!(number: 'OPEN-STOCK', purpose: 'program_stock', stock: [{ product_id: @product.id, quantity: 1 }])
      open_stock.update!(created_at: 3.weeks.ago)
      cancelled_stock = BidGroup.create!(number: 'CANCELLED-STOCK', purpose: 'program_stock', cancelled_at: Time.current)
      awarded_stock = BidGroup.create!(number: 'AWARDED-STOCK', purpose: 'program_stock', purchase_order: create(:purchase_order, purpose: 'program_stock'))
      direct = BidGroup.create!(number: 'DIRECT-BID', purpose: 'direct_to_constituents')

      get admin_stock_index_path

      ['Model', 'Available', 'Reserved for dispatch', 'Incoming', 'Buy for stock'].each do |heading|
        assert_select 'th[scope=col]', text: heading
      end
      assert_select 'a[href="#buy-stock"]', text: 'Create a bid to buy stock'
      assert_select 'a[href=?]', admin_bid_groups_path(purpose: 'program_stock', state: 'open'), text: 'Open bids for stock: 1'
      assert_select "select#stock-setup-#{@product.id}-0 option[value='']", text: 'Unassigned'
      assert_select '[data-stock-purchase-target=template]'
      assert_select 'input[type=submit][value="Review stock bid"]'

      association_queries = []
      observer = lambda do |_name, _start, _finish, _id, payload|
        association_queries << payload[:sql] if payload[:sql].match?(/FROM "products"/)
      end
      ActiveSupport::Notifications.subscribed(observer, 'sql.active_record') do
        get admin_bid_groups_path(purpose: 'program_stock', state: 'open')
      end

      assert_equal 2, association_queries.size, 'Only the oldest request and bid should load a product for navigation'
      assert_select 'article', text: /Bid OPEN-STOCK.*Program stock.*MAT.*Awaiting award.*Open 3 weeks/m
      assert_select 'nav[aria-label="Equipment sections"] article:nth-child(2)' do
        assert_select 'p', text: '1 bid awaiting award'
        assert_select 'p', text: 'Longest wait: 3 weeks'
        assert_select 'a[href=?]', new_admin_purchase_order_path(bid_group_id: open_stock.id), text: 'Program stock'
      end
      assert_select 'article a[href=?]', admin_bid_group_path(open_stock), text: 'Bid OPEN-STOCK'
      [cancelled_stock, awarded_stock, direct].each do |group|
        assert_no_match(/Bid #{Regexp.escape(group.number)}/, response.body)
      end
    end

    test 'an empty released bid stays open without offering award or counting as awaiting award' do
      bid = Equipment::Bidding.new(actor: @admin).create!(number: 'EMPTY-REUSABLE-BID', needs: [{ id: @need.id, quantity: 1, lock_version: @need.lock_version }])
      Equipment::Bidding.new(actor: @admin).release!(group: bid, line_ids: bid.active_lines.ids, expected_version: bid.lock_version, reason: 'Waiting for a corrected quote')
      get admin_bid_groups_path
      assert_response :success
      assert_select 'article', text: /Bid EMPTY-REUSABLE-BID.*Open — no products reserved/m
      assert_select '.grid > .border', text: /Enter PO details:\s*0 bids/
      get admin_bid_group_path(bid)
      assert_response :success
      assert_select 'p', text: /No products are reserved under this bid/
      assert_select 'a[href=?]', admin_equipment_index_path(tab: 'needs_ordering'), text: 'Choose products'
      assert_select 'a[href^=?]', new_admin_purchase_order_path, count: 0
      assert_select 'button', text: 'Save quantities', count: 0
      assert_select 'input[type=submit][value="Release selected reservations"]', count: 0
      assert_select 'button[name=cancel]', text: 'Cancel entire bid'
      patch admin_bid_group_path(bid), params: { expected_version: bid.reload.lock_version, reason: 'This external bid is no longer needed', cancel: '1' }
      assert_redirected_to admin_bid_group_path(bid)
      assert bid.reload.cancelled_at
    end

    test 'bid details retain the purchasing section and parent view' do
      signing_hand = create(:product, name: 'Bid signing hand')
      stock = [{ product_id: @product.id, quantity: 4, supplier_setup_group: 'speech' },
               { product_id: signing_hand.id, quantity: 5, supplier_setup_group: 'deaf' }]
      bid = Equipment::Bidding.new(actor: @admin).create!(number: 'NAVIGATION-BID', purpose: 'program_stock', stock: stock)
      get admin_bid_group_path(bid)

      assert_response :success
      assert_equipment_sections('Enter PO details')
      assert_select 'nav[aria-label="Enter PO details views"]' do
        assert_select 'a', count: 2
        assert_select 'a[aria-current=location]', count: 1
        assert_select 'a[aria-current=location][href=?]', admin_bid_groups_path, text: 'Bids'
        assert_select 'a[aria-current=page]', count: 0
      end
      assert_select 'nav[aria-label="Return navigation"]' do
        assert_select 'a[href=?]', admin_dashboard_path, text: 'Back to Dashboard'
        assert_select 'a[href=?]', admin_applications_path, text: 'Back to Applications'
      end
      assert_select 'article h2', text: @product.catalog_label
      assert_select 'article h2', text: signing_hand.catalog_label
      assert_select 'article dt', text: 'Destination:', count: 2
      assert_select 'article dd', text: 'Stock', count: 2
      assert_select 'article dd', text: '4 Speech'
      assert_select 'article dd', text: '5 Deaf'
      assert_select 'article label', text: 'Release this reservation', count: 2
      assert_select '#bid-history[open]' do
        assert_select 'p', text: /Bid created — #{Regexp.escape(@admin.full_name)}/
        assert_select 'time[datetime]'
        assert_select 'dd', text: /#{Regexp.escape(@product.catalog_label)}/
      end
    end

    test 'purchase order details link back to purchase orders and the dashboard' do
      order = create(:purchase_order)
      get admin_purchase_order_path(order)

      assert_response :success
      assert_select 'nav[aria-label="Equipment sections"], nav[aria-label="Enter PO details views"]', count: 0
      assert_select 'nav[aria-label="Return navigation"]' do
        assert_select 'a[href=?]', admin_dashboard_path, text: 'Back to Dashboard'
        assert_select 'a[href=?]', admin_purchase_orders_path, text: 'Back to Purchase Orders'
      end
    end

    private

    def assert_equipment_sections(current_section)
      assert_select 'nav[aria-label="Equipment sections"]' do
        assert_select 'a.summary-card-content', count: 3
        assert_select 'a.summary-card-content[href=?][data-turbo-frame="_top"]', admin_equipment_index_path(tab: 'needs_ordering'), text: 'Needs bid number'
        assert_select 'a.summary-card-content[href=?][data-turbo-frame="_top"]', admin_bid_groups_path, text: 'Enter PO details'
        assert_select 'a.summary-card-content[href=?][data-turbo-frame="_top"]', admin_stock_index_path, text: 'Stock'
        assert_select 'a.summary-card-content[aria-current=location]', count: 1
        assert_select 'a.summary-card-content[aria-current=location]', text: current_section, count: 1
      end
    end
  end
end
