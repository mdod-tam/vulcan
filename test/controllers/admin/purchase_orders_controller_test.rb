# frozen_string_literal: true

require 'test_helper'

module Admin
  class PurchaseOrdersControllerTest < ActionDispatch::IntegrationTest
    setup do
      @admin = create(:admin)
      @phone = create(:product, name: 'Ordering Phone')
      @need = create(:equipment_need, product: @phone, remaining_quantity: 2)
      @context = { tab: 'needs_ordering', product_id: @phone.id.to_s }
      @group = Equipment::Bidding.new(actor: @admin).create!(number: 'REQUEST-BID', needs: [{ id: @need.id, lock_version: @need.lock_version, quantity: 2 }])
      sign_in_for_integration_test(@admin, bypass_mfa_enrollment: true)
    end

    test 'bid award review carries fixed current lines versions and full destination' do
      create(:purchase_order, vendor_name: 'Previous Supplier')
      get new_admin_purchase_order_path(bid_group_id: @group.id, return_context: @context)
      assert_response :success
      assert_select 'h1', text: 'Enter PO details for bid REQUEST-BID'
      assert_select 'input[name="bid_group_id"][value=?]', @group.id.to_s
      line = @group.active_lines.sole
      assert_select 'input[name=?][value="0"]', "line_versions[#{line.id}]"
      assert_select 'input[name="return_context[product_id]"][value=?]', @phone.id.to_s
      assert_includes response.body, @need.application.shipping_address_1
      assert_select 'select[name="purchase_order[vendor_id]"]', count: 0
      assert_select 'input[name="purchase_order[sent_at]"]', count: 0
      assert_select 'input[name="purchase_order[vendor_name]"][list="purchase-order-vendors"]'
      assert_select '#purchase-order-vendors option[value="Previous Supplier"]'
      assert_select 'input[name=?][inputmode="decimal"]', "line_unit_costs[#{line.id}]"
      assert_select 'input[name*="imei"], input[name*="serial_number"]', count: 0
    end

    test 'award creates unsent units and sent action exposes the actual sent boundary' do
      assert_difference 'PurchaseOrder.count', 1 do
        assert_difference 'EquipmentItem.count', 2 do
          post admin_purchase_orders_path, params: submission
        end
      end
      order = PurchaseOrder.find_by!(number: 'PO-0042')
      assert_redirected_to admin_purchase_order_path(order, return_context: @context)
      assert_nil order.sent_at
      assert_equal 'Awarded Supplier', order.vendor_name
      assert_equal [BigDecimal('1234.50')], order.equipment_items.distinct.pluck(:unit_cost)
      assert_equal 0, @need.reload.remaining_quantity
      order.equipment_items.first.update!(serial_number: 'ORDERED-SERIAL', imei: '123456789012345')
      get admin_purchase_order_path(order)
      assert_response :success
      assert_includes response.body, 'PO sent date needed'
      assert_includes response.body, @need.application.shipping_address_1
      assert_select '#supplier-list-heading', text: 'Supplier order list'
      assert_select 'section[aria-labelledby="supplier-list-heading"]' do
        assert_select 'p', text: 'Share this list with the vendor, along with any setup instructions they agreed to follow.'
        assert_select 'th', text: /Disability setup|Shipment/, count: 0
        assert_select '[role="region"][tabindex="0"][aria-labelledby="supplier-list-heading"] table'
        assert_select 'td', text: /#{Regexp.escape(@need.application.shipping_address_1)}/
        assert_select '#supplier-list-text[readonly]', text: /PO PO-0042/
      end
      assert_select '#purchase-order-device-records' do
        assert_select 'h2', text: 'Device tracking and records'
        assert_select 'article', count: 2
        assert_select 'dt', text: 'Funding', count: 2
        assert_select 'dt + dd', text: 'ORDERED-SERIAL', count: 1
        assert_select 'dt + dd', text: '123456789012345', count: 1
        assert_select 'dt', text: /Onward destination|Required setup|Purchase order|Where it came from/, count: 0
        assert_select 'input', count: 0
        assert_select 'a.btn.btn-outline', text: 'Edit price and receipt dates', count: 2
        assert_select 'a.btn.btn-outline', text: 'Correct device or shipping details', count: 2
      end
      assert_select 'a.btn.btn-outline[href=?]', edit_admin_icanconnect_financial_record_path("PurchaseOrder:#{order.id}"),
                    text: 'Edit PO invoice and charges'
      assert_select '#purchase-order-history[open]' do
        assert_select 'p', text: /PO recorded — #{Regexp.escape(@admin.full_name)}/
        assert_select 'time[datetime]'
        assert_select 'p', text: /Awarded Supplier/
      end
      patch send_order_admin_purchase_order_path(order), params: { sent_at: Date.current.iso8601, expected_version: order.lock_version }
      assert_redirected_to admin_purchase_order_path(order)
      assert_equal Date.current, order.reload.sent_at
      follow_redirect!
      assert_select '#vendor-shipping h2', text: 'Vendor tracking link'
      assert_select '#vendor-shipping summary', text: 'Email tracking link'
      assert_select '#purchase-order-device-records a', text: 'Enter shipping info', count: 2
    end

    test 'invalid new PO retry preserves submitted number fixed line versions and return context' do
      parameters = submission
      parameters[:purchase_order][:number] = ''
      2.times do
        assert_no_difference ['PurchaseOrder.count', 'EquipmentItem.count', 'Event.count'] do
          post admin_purchase_orders_path, params: parameters
        end
        assert_response :unprocessable_content
        assert_select '[role=alert]', text: /PO number/
        assert_select 'input[name="purchase_order[number]"][value=""]'
        assert_select 'input[name="purchase_order[vendor_name]"][value="Awarded Supplier"]'
        assert_select 'input[name=?][value="$1,234.50"]', "line_unit_costs[#{@group.active_lines.sole.id}]"
        assert_select 'input[name="return_context[product_id]"][value=?]', @phone.id.to_s
      end
      parameters[:purchase_order][:number] = 'CORRECTED-PO'
      assert_difference 'EquipmentItem.count', 2 do
        post admin_purchase_orders_path, params: parameters
      end
      assert_response :redirect
    end

    test 'malformed prices retain the award draft without consuming the bid' do
      parameters = submission
      line = @group.active_lines.sole
      parameters[:line_unit_costs][line.id.to_s] = '12.345'
      assert_no_difference ['PurchaseOrder.count', 'EquipmentItem.count', 'Event.count'] do
        post admin_purchase_orders_path, params: parameters
      end
      assert_response :unprocessable_content
      assert_select '[role=alert]', text: /Enter a valid price per device/
      assert_select 'input[name=?][value="12.345"]', "line_unit_costs[#{line.id}]"
      assert_select 'input[name="purchase_order[number]"][value="PO-0042"]'
      assert_select 'input[name="purchase_order[vendor_name]"][value="Awarded Supplier"]'
      assert_equal 2, @need.reload.remaining_quantity
      assert @group.reload.open?
      parameters[:line_unit_costs][line.id.to_s] = ''
      post admin_purchase_orders_path, params: parameters
      assert_response :redirect
      assert_equal [nil], PurchaseOrder.find_by!(number: 'PO-0042').equipment_items.distinct.pluck(:unit_cost)
    end

    test 'stale bid versions reject the whole award without consumption' do
      parameters = submission
      @group.update!(membership_changed_at: Time.current)
      assert_no_difference ['PurchaseOrder.count', 'EquipmentItem.count', 'Event.count'] do
        post admin_purchase_orders_path, params: parameters
      end
      assert_response :unprocessable_content
      assert_equal 2, @need.reload.remaining_quantity
      assert @group.reload.open?
    end

    test 'a missing bid at submission returns not found without trying to rebuild its award review' do
      parameters = submission.merge(bid_group_id: BidGroup.maximum(:id) + 1)
      assert_no_difference ['PurchaseOrder.count', 'EquipmentItem.count', 'Event.count'] do
        post admin_purchase_orders_path, params: parameters
      end
      assert_response :not_found
      assert_equal 2, @need.reload.remaining_quantity
      assert @group.reload.open?
    end

    test 'malformed actual prices do not change saved prices supplier or history' do
      post admin_purchase_orders_path, params: submission
      order = PurchaseOrder.find_by!(number: 'PO-0042')
      units = order.equipment_items.order(:id).to_a
      ['garbage', '12.345'].each do |invalid|
        rows = units.each_with_index.map { |unit, index| { id: unit.id, lock_version: unit.lock_version, unit_cost: index.zero? ? '25.50' : invalid } }
        assert_no_difference 'Event.count' do
          patch admin_purchase_order_cost_path(order),
                params: { costs: { expected_version: order.lock_version, vendor_name: 'Must not replace supplier', rows: rows } }
        end
        assert_response :unprocessable_content
        assert_select '[role=alert]', text: /Enter a valid price per device/
        assert_select 'input[name="costs[rows][][unit_cost]"][type=text][inputmode=decimal][value=?]', invalid
        assert_equal 'Awarded Supplier', order.reload.vendor_name
        assert_equal [BigDecimal('1234.50')], order.equipment_items.distinct.pluck(:unit_cost)
      end
    end

    test 'changed shipping review preserves its draft and requires explicit refresh before award' do
      parameters = submission
      reviewed = parameters[:application_versions].dup
      @need.application.update!(shipping_address_1: 'Current confirmed destination')
      assert_no_difference ['PurchaseOrder.count', 'EquipmentItem.count'] do
        post admin_purchase_orders_path, params: parameters
      end
      assert_response :unprocessable_content
      assert_select '[role=alert]', text: /Application details changed/
      assert_select 'input[name="purchase_order[number]"][value="PO-0042"]'
      assert_select 'input[name="purchase_order[vendor_name]"][value="Awarded Supplier"]'
      assert_select 'input[name=?][value="$1,234.50"]', "line_unit_costs[#{@group.active_lines.sole.id}]"
      assert_select 'input[name=?][value=?]', "application_versions[#{@need.application_id}]", reviewed.fetch(@need.application_id.to_s)

      post admin_purchase_orders_path, params: parameters.merge(refresh_profiles: '1')
      assert_response :success
      assert_select '[role=status]', text: /The shipping address and device setup have been refreshed/
      assert_includes response.body, 'Current confirmed destination'
      assert_select 'input[name="purchase_order[vendor_name]"][value="Awarded Supplier"]'
      assert_select 'input[name=?][value="$1,234.50"]', "line_unit_costs[#{@group.active_lines.sole.id}]"
      parameters[:application_versions] = css_select('input[name^="application_versions["]').to_h do |input|
        [input['name'][/\[(\d+)\]/, 1], input['value']]
      end
      assert_difference('EquipmentItem.count', 2) { post admin_purchase_orders_path, params: parameters }
      assert_response :redirect
      assert_equal ['Current confirmed destination'], EquipmentItem.where(application_id: @need.application_id).map(&:shipping_address_1).uniq
    end

    test 'explicit unsent same purpose reuse ignores unused new number and retains fixed membership' do
      order = create(:purchase_order, sent_at: nil, vendor_name: 'Existing Supplier')
      parameters = submission
      parameters[:purchase_order][:existing] = "#{order.id}:#{order.lock_version}"
      parameters[:purchase_order][:number] = 'UNUSED-HEADER'
      assert_no_difference 'PurchaseOrder.count' do
        assert_difference 'EquipmentItem.count', 2 do
          post admin_purchase_orders_path, params: parameters
        end
      end
      assert_redirected_to admin_purchase_order_path(order, return_context: @context)
      assert_equal 2, order.equipment_items.count
      assert_not_equal 'UNUSED-HEADER', order.reload.number
      assert_equal 'Existing Supplier', order.vendor_name
      assert_equal [BigDecimal('1234.50')], order.equipment_items.distinct.pluck(:unit_cost)
    end

    test 'vendor and unrelated constituent cannot reach award or PO operational data' do
      [create(:vendor), create(:constituent)].each do |actor|
        sign_in_for_integration_test(actor, bypass_mfa_enrollment: true)
        get new_admin_purchase_order_path(bid_group_id: @group.id)
        assert_redirected_to root_path
        assert_no_difference ['PurchaseOrder.count', 'EquipmentItem.count'] do
          post admin_purchase_orders_path, params: submission
        end
        assert_redirected_to root_path
      end
    end

    private

    def submission
      { bid_group_id: @group.id, application_versions: equipment_bid_profile_versions(@group), expected_version: @group.lock_version,
        line_versions: @group.active_lines.to_h { |line| [line.id.to_s, line.lock_version.to_s] },
        return_context: @context, purchase_order: { number: 'PO-0042', vendor_name: 'Awarded Supplier' },
        line_unit_costs: @group.active_lines.to_h { |line| [line.id.to_s, '$1,234.50'] } }
    end
  end
end
