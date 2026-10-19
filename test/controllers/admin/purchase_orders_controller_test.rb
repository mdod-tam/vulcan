# frozen_string_literal: true

require 'test_helper'

module Admin
  class PurchaseOrdersControllerTest < ActionDispatch::IntegrationTest
    setup do
      @admin = create(:admin)
      @vendor = create(:vendor)
      @phone = create(:product, name: 'Ordering Phone')
      @phone_need = create(:equipment_need, product: @phone)
      @other_need = create(:equipment_need, application: @phone_need.application)
      @two_phones = create(:equipment_need, product: @phone, remaining_quantity: 2)
      @context = { tab: 'needs_ordering', product_id: @phone.id.to_s, vendor_id: @vendor.id.to_s }
      @phone.vendors << @vendor
      sign_in_for_integration_test(@admin)
    end

    test 'exact model group review carries all application quantities and record versions' do
      get new_admin_purchase_order_path(group_product_ids: [@phone.id], return_context: @context)

      assert_response :success
      assert_select 'h1', text: 'Record Winning Bid & PO'
      assert_select '[role=status]', text: /3 physical units across 2 applications/
      assert_includes response.body, 'New devices to materialize'
      assert_includes response.body, 'Previously ordered devices to relink'
      [@phone_need, @two_phones].each do |need|
        assert_select 'input[name="purchase_order[needs][][id]"][value=?]', need.id.to_s
        assert_select "#quantity_#{need.id}[value=?]", need.remaining_quantity.to_s
      end
      assert_select 'input[name="purchase_order[needs][][lock_version]"][value="0"]', count: 2
      assert_select 'input[name="return_context[product_id]"][value=?]', @phone.id.to_s
      assert_select 'a[href=?]', admin_equipment_index_path(@context), text: 'Back to Equipment'
      assert_select 'input[name="purchase_order[needs][][id]"][value=?]', @other_need.id.to_s, count: 0
    end

    test 'all equipment vendor pickers use account eligibility including legacy accounts' do
      legacy = create(:vendor, status: nil)
      excluded = [create(:vendor, status: :inactive), create(:vendor, status: :suspended),
                  create(:vendor, merged_into_user: @vendor, merged_at: Time.current)]
      item = create(:equipment_item, purchase_order: create(:purchase_order, vendor: @vendor))
      forms = {
        new_admin_purchase_order_path(need_ids: [@phone_need.id]) => '#purchase_order_vendor_id',
        edit_admin_purchase_order_correction_path(item.purchase_order) => '#purchase_order_vendor_id',
        edit_admin_equipment_item_path(item) => '#new_purchase_order_vendor_id'
      }

      forms.each do |path, picker|
        get path

        assert_response :success
        [@vendor, legacy].each { |vendor| assert_select "#{picker} option[value=?]", vendor.id.to_s }
        excluded.each { |vendor| assert_select "#{picker} option[value=?]", vendor.id.to_s, count: 0 }
      end
    end

    test 'one create records the four unit example on a shared PO through the request boundary' do
      assert_difference('PurchaseOrder.count', 1) do
        assert_difference('EquipmentItem.count', 4) { post admin_purchase_orders_path, params: submission }
      end

      order = PurchaseOrder.find_by!(vendor: @vendor, number: '00042')
      assert_redirected_to admin_purchase_order_path(order, return_context: @context)
      assert_equal 4, order.equipment_items.count
      assert_equal 2, order.equipment_items.where(application: @two_phones.application, product: @phone).distinct.count(:id)
      assert_equal([0, 0, 0], needs.map { |need| need.reload.remaining_quantity })
      assert_nil @phone_need.application.reload.equipment_po_sent_at
      selects = Hash.new { |hash, key| hash[key] = [] }
      subscriber = lambda do |*arguments|
        payload = arguments.last
        next unless payload[:sql].match?(/\ASELECT\b/)

        # Count cached SELECTs too, so query caching cannot conceal per-device loads.
        selects[:purchase_orders] << payload[:sql] if payload[:sql].include?('FROM "purchase_orders"')
        selects[:vendors] << payload[:sql] if payload[:sql].include?('FROM "users"') && payload[:name].include?('Users::Vendor')
      end
      ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
        get admin_purchase_order_path(order, return_context: @context)
      end
      assert_response :success
      assert_includes response.body, 'Awaiting Shipment'
      assert_operator selects.fetch(:purchase_orders).size, :<=, 2, selects[:purchase_orders].join("\n")
      # The header, audit POs, and direct vendor changes each load vendors once.
      assert_operator selects.fetch(:vendors).size, :<=, 3, selects[:vendors].join("\n")
      order.equipment_items.each do |item|
        assert_select "#equipment-item-#{item.id}" do
          assert_select 'a[href=?]', admin_purchase_order_path(order, return_context: @context), text: "#{@vendor.business_name} / #{order.number}"
        end
      end
      get admin_purchase_orders_path(return_context: @context)
      assert_select 'a[href=?]', admin_equipment_index_path(@context), text: 'Back to Equipment'
      assert_select 'a[href=?]', admin_purchase_order_path(order, return_context: @context)
      assert_select 'li', text: /4 units across 2 applications/
    end

    test 'invalid PO retry retains reduced quantities header values versions and filter context' do
      parameters = submission
      parameters[:purchase_order][:needs].last[:quantity] = '1'
      parameters[:purchase_order][:sent_at] = '13/45/2026'

      2.times do
        assert_no_difference(['PurchaseOrder.count', 'EquipmentItem.count', 'Event.count']) do
          post admin_purchase_orders_path, params: parameters
        end
        assert_response :unprocessable_entity
        assert_select '#purchase-order-errors[role=alert][tabindex="-1"][data-controller=error-summary]'
        assert_select '[role="alert"]', text: /Date PO sent/
        assert_select "#quantity_#{@two_phones.id}[value='1']"
        assert_select '#purchase_order_vendor_id option[selected][value=?]', @vendor.id.to_s
        assert_select '#purchase_order_number[value="00042"]'
        assert_select '#purchase_order_sent_at[value="13/45/2026"]'
        assert_select '#purchase_order_sent_at[aria-invalid=true][aria-describedby="purchase_order_sent_at-help purchase_order_sent_at-error"]'
        assert_select '#purchase_order_sent_at-error', text: /Date PO sent is invalid/
        assert_select 'input[name="purchase_order[needs][][lock_version]"][value="0"]', count: 3
        assert_select 'input[name="return_context[vendor_id]"][value=?]', @vendor.id.to_s
        assert_select 'a[href=?]', admin_equipment_index_path(@context), text: 'Back to Equipment'
      end

      parameters[:purchase_order][:sent_at] = Date.current.strftime('%m/%d/%Y')
      assert_difference('EquipmentItem.count', 3) { post admin_purchase_orders_path, params: parameters }
      assert_response :redirect
      assert_equal 1, @two_phones.reload.remaining_quantity
    end

    test 'explicit existing PO selection ignores new header fields and retains the detached device ID' do
      order = create(:purchase_order, vendor: @vendor)
      detached = create(:equipment_item, application: @phone_need.application, product: @phone, purchase_order: nil)
      parameters = submission
      parameters[:purchase_order].merge!(
        existing: "#{order.id}:#{order.lock_version}", sent_at: 'not-a-date', number: 'Unused new number',
        needs: [{ id: @phone_need.id, quantity: 1, lock_version: @phone_need.lock_version }],
        items: [{ id: detached.id, lock_version: detached.lock_version }]
      )

      assert_no_difference('PurchaseOrder.count') do
        assert_difference('EquipmentItem.count', 1) { post admin_purchase_orders_path, params: parameters }
      end
      assert_redirected_to admin_purchase_order_path(order, return_context: @context)
      assert_equal order.id, detached.reload.purchase_order_id
      assert_equal 2, order.equipment_items.count
      assert_not_equal 'Unused new number', order.reload.number
    end

    test 'one stale need rejects the entire request and keeps the original review versions' do
      parameters = submission
      @two_phones.update!(remaining_quantity: 3)

      assert_no_difference(['PurchaseOrder.count', 'EquipmentItem.count', 'Event.count']) do
        post admin_purchase_orders_path, params: parameters
      end
      assert_response :unprocessable_entity
      assert_select '[role="alert"]', text: /Refresh and review/
      assert_select 'input[name="purchase_order[needs][][lock_version]"][value="0"]', count: 3
      assert_equal([1, 1, 3], needs.map { |need| need.reload.remaining_quantity })
    end

    test 'a completed request cannot be repeated and purchasing routes reject vendors' do
      parameters = submission
      post admin_purchase_orders_path, params: parameters
      assert_response :redirect
      assert_no_difference(['PurchaseOrder.count', 'EquipmentItem.count', 'Event.count']) do
        post admin_purchase_orders_path, params: parameters
      end
      assert_response :unprocessable_entity

      sign_in_for_integration_test(@vendor)
      get new_admin_purchase_order_path(need_ids: [@other_need.id])
      assert_redirected_to root_path
      assert_no_difference(['PurchaseOrder.count', 'EquipmentItem.count', 'Event.count']) do
        post admin_purchase_orders_path, params: parameters
      end
      assert_redirected_to root_path
    end

    private

    def needs
      [@phone_need, @other_need, @two_phones]
    end

    def submission
      {
        return_context: @context,
        purchase_order: {
          vendor_id: @vendor.id, number: '00042', sent_at: Date.current.strftime('%m/%d/%Y'),
          needs: needs.map { |need| { id: need.id, quantity: need.remaining_quantity, lock_version: need.lock_version } }, items: []
        }
      }
    end
  end
end
