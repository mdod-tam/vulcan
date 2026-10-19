# frozen_string_literal: true

require 'test_helper'

module Admin
  class EquipmentItemsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @admin = create(:admin)
      @item = create(:equipment_item)
      sign_in_for_integration_test(@admin)
    end

    test 'item forms and writes require an administrator' do
      sign_in_for_integration_test(create(:evaluator))
      get edit_admin_equipment_item_path(@item)
      assert_redirected_to root_path
      assert_no_difference 'Event.count' do
        patch admin_equipment_item_path(@item), headers: { 'Accept' => Mime[:turbo_stream].to_s },
                                                params: { equipment_item: { tracking_number: 'Blocked' }, expected_version: 0, reason: 'Unauthorized' }
      end
      assert_redirected_to root_path
      assert_nil @item.reload.tracking_number
    end

    test 'invalid shipment re-renders every entered field and validated return context' do
      patch admin_equipment_item_path(@item), headers: { 'Accept' => Mime[:turbo_stream].to_s }, params: {
        equipment_item: { product_id: @item.product_id, purchase_order_id: @item.purchase_order_id, shipped_at: '13/45/2026',
                          tracking_number: 'RetryPackage', carrier: 'fedex', serial_number: 'RetrySerial', imei: '123456789012345' },
        expected_version: 0, reason: 'Record shipment', return_context: { tab: 'ordered', product_id: @item.product_id, vendor_id: @item.purchase_order.vendor_id }
      }
      assert_response :unprocessable_entity
      assert_equal Mime[:html].to_s, response.media_type
      assert_select '#equipment-correction form[data-turbo=false]', count: 0
      assert_select '#equipment-item-errors[role=alert][tabindex="-1"][data-controller=error-summary]'
      assert_select '#equipment-item-errors li', text: /Date shipped is invalid/
      assert_select 'input[name="equipment_item[shipped_at]"][value="13/45/2026"]'
      assert_select '#equipment_item_shipped_at[aria-invalid=true][aria-describedby="equipment-ship-date-help equipment-ship-date-error"]'
      assert_select '#equipment-ship-date-error', text: /Date shipped is invalid/
      assert_select 'input[name="equipment_item[tracking_number]"][value="RetryPackage"]'
      assert_select 'input[name="equipment_item[serial_number]"][value="RetrySerial"]'
      assert_select 'input[name="equipment_item[imei]"][value="123456789012345"]'
      assert_select 'select[name="equipment_item[carrier]"] option[value="fedex"][selected]'
      assert_select 'textarea[name=reason]', text: 'Record shipment'
      assert_select 'input[name="return_context[tab]"][value=ordered]'
      assert_nil @item.reload.shipped_at
      assert_nil @item.tracking_number
      replacement = create(:product)
      patch admin_equipment_item_path(@item), params: { review: '1', equipment_item: { product_id: replacement.id, shipped_at: Date.current, carrier: 'usps',
                                                                                       imei: '123456789012345' }, expected_version: 0, reason: 'Review replacement model' }
      original_label = "#{@item.product.manufacturer} / #{@item.product.name} / #{@item.product.model_number}"
      replacement_label = "#{replacement.manufacturer} / #{replacement.name} / #{replacement.model_number}"
      assert_response :success
      assert_equal Mime[:html].to_s, response.media_type
      assert_select '#equipment-correction form input[name=impact_token]'
      assert_select '#equipment-correction form[data-turbo=false]', count: 0
      assert_select 'dd', text: /#{Regexp.escape(original_label)}\s*→\s*#{Regexp.escape(replacement_label)}/
      assert_select 'dt', text: 'Actual catalog product:'
      assert_select 'dt', text: 'Date shipped:'
      assert_select 'dt', text: 'IMEI (15 digits):'
      assert_select 'dd', text: "Not recorded → #{Date.current.strftime('%m/%d/%Y')}"
      assert_select 'dd', text: 'Not recorded → USPS'
      assert_select 'dt', count: 4
    end

    test 'identity conflict links are available only in the authorized correction form' do
      conflict = create(:equipment_item, imei: '123456789012345')
      context = { tab: 'ordered', product_id: @item.product_id.to_s, vendor_id: @item.purchase_order.vendor_id.to_s }
      patch admin_equipment_item_path(@item), params: { equipment_item: { imei: '123456789012345' }, expected_version: 0, reason: 'Identify device', return_context: context }
      assert_response :unprocessable_entity
      assert_select 'a[href=?]', edit_admin_equipment_item_path(conflict, return_context: context), text: "Review equipment item ##{conflict.id}"
      assert_select '[role=alert]', text: /IMEI/
      assert_nil @item.reload.imei
    end

    test 'a linked device can be detached only through the explicit correction action' do
      get edit_admin_equipment_item_path(@item)
      assert_select '#equipment_item_purchase_order_id option[value=""]', count: 0
      assert_select '#operation option[value=detach]', text: 'Detach an unshipped device for reorder'

      Equipment::Correction.new(actor: @admin).update_item!(item: @item, attributes: {}, expected_version: 0, reason: 'Await a replacement order', operation: 'detach')
      get edit_admin_equipment_item_path(@item)
      assert_select '#equipment_item_purchase_order_id option[value=""]', text: 'No current purchase order'
    end

    test 'shipment save preserves allowlisted equipment tab and filters' do
      @item.update!(shipped_at: Date.current, tracking_number: 'OriginalPackage')
      context = { tab: 'shipped', product_id: @item.product_id.to_s, vendor_id: @item.purchase_order.vendor_id.to_s }
      submitted = { equipment_item: { shipped_at: Date.current.iso8601, tracking_number: 'Package' }, operation: 'update',
                    expected_version: @item.lock_version, reason: 'Record actual shipment', return_context: context,
                    purchase_order_versions: { @item.purchase_order_id.to_s => @item.purchase_order.lock_version.to_s } }
      headers = { 'Accept' => Mime[:turbo_stream].to_s }
      assert_no_difference 'Event.count' do
        patch admin_equipment_item_path(@item), headers: headers, params: submitted.merge(review: '1')
      end
      assert_response :success
      assert_equal Mime[:turbo_stream].to_s, response.media_type
      assert_select 'turbo-stream[action=replace][target=equipment-correction]', count: 1 do
        assert_select 'template #equipment-correction form[action=?]', admin_equipment_item_path(@item)
        assert_select 'input[name=expected_version][value=?]', submitted[:expected_version].to_s
        assert_select 'input[name=reviewing][value="1"]'
        assert_select 'input[name=confirmed_impact][required]:not([checked])'
        assert_select 'button[name=review][value="1"][data-turbo-submits-with]', text: 'Review changed values'
        assert_select 'input[type=submit][data-turbo-submits-with][value="Save equipment correction"]'
        assert_select 'form[data-turbo=false]', count: 0
      end
      token = css_select('input[name=impact_token]').sole['value']
      assert token.present?
      assert_difference 'Event.count', 1 do
        patch admin_equipment_item_path(@item), headers: headers,
                                                params: submitted.merge(reviewing: '1', confirmed_impact: '1', impact_token: token)
      end
      assert_response :see_other
      assert_redirected_to admin_equipment_index_path(context)
      assert_equal Date.current, @item.reload.shipped_at
      assert_equal 'Package', @item.tracking_number
    end

    test 'mixed detach edits retain the rejected draft until details are saved separately' do
      original = @item.attributes
      context = { tab: 'ordered', product_id: @item.product_id.to_s, vendor_id: @item.purchase_order.vendor_id.to_s }
      submitted = {
        equipment_item: { product_id: @item.product_id.to_s, purchase_order_id: @item.purchase_order_id.to_s,
                          shipped_at: '', tracking_number: '', carrier: '', serial_number: 'CorrectedSerial', imei: '' },
        operation: 'detach', expected_version: '0', reason: 'Correct identity before reorder', return_context: context
      }
      2.times do
        assert_no_difference ['PurchaseOrder.count', 'EquipmentItem.count', 'Event.count'] do
          patch admin_equipment_item_path(@item), params: submitted
        end
        assert_response :unprocessable_entity
        assert_select '#equipment-item-errors[role=alert][tabindex="-1"][data-controller=error-summary]', text: /Save device details separately/
        assert_select '#equipment_item_serial_number[value=CorrectedSerial]'
        assert_select '#operation option[value=detach][selected]'
        assert_select '#reason', text: 'Correct identity before reorder'
        assert_select '#expected_version[value="0"]'
        assert_select 'input[name="return_context[tab]"][value=ordered]'
        assert_equal original, @item.reload.attributes
      end

      assert_difference 'Event.count', 1 do
        patch admin_equipment_item_path(@item), params: submitted.merge(operation: 'update')
      end
      assert_redirected_to admin_equipment_index_path(context)
      assert_equal 'CorrectedSerial', @item.reload.serial_number
      assert_equal original['purchase_order_id'], @item.purchase_order_id
    end

    test 'stale form retains its submitted fences and an unchanged retry cannot overwrite another administrator' do
      @item.update!(shipped_at: Date.current, tracking_number: 'OriginalPackage')
      submitted_version = @item.lock_version.to_s
      params = { equipment_item: { tracking_number: 'StaleDraft' }, expected_version: submitted_version, reason: 'Old browser tab',
                 purchase_order_versions: { @item.purchase_order_id.to_s => '0' } }
      headers = { 'Accept' => Mime[:turbo_stream].to_s }
      patch admin_equipment_item_path(@item), headers: headers, params: params.merge(review: '1')
      assert_response :success
      assert_select 'turbo-stream[action=replace][target=equipment-correction] template #equipment-correction'
      token = css_select('input[name=impact_token]').sole['value']
      params.merge!(reviewing: '1', confirmed_impact: '1', impact_token: token)
      @item.update!(tracking_number: 'OtherAdministratorPackage')
      2.times do
        assert_no_difference 'Event.count' do
          patch admin_equipment_item_path(@item), headers: headers, params: params
        end
        assert_response :unprocessable_entity
        assert_equal Mime[:html].to_s, response.media_type
        assert_select '#equipment-correction form[data-turbo=false]', count: 0
        assert_select 'input[name=expected_version][value=?]', submitted_version
        assert_select 'input[name=impact_token][value=?]', token
        assert_select 'input[name=confirmed_impact]:not([checked])'
        assert_select 'input[name="equipment_item[tracking_number]"][value=StaleDraft]'
        assert_equal 'OtherAdministratorPackage', @item.reload.tracking_number
      end
    end

    test 'stale selected PO versions stay stale on an unchanged retry' do
      target = create(:purchase_order)
      original_order_id = @item.purchase_order_id
      Equipment::Correction.new(actor: @admin).update_purchase_order!(purchase_order: target, attributes: { number: 'Revised target header' },
                                                                      expected_version: 0, expected_item_versions: {}, reason: 'Another tab revised the target')
      2.times do
        assert_no_difference 'Event.count' do
          patch admin_equipment_item_path(@item), params: { equipment_item: { purchase_order_id: target.id }, reason: 'Old target selection',
                                                            expected_version: '0', purchase_order_versions: { target.id.to_s => '0' } }
        end
        assert_response :unprocessable_entity
        assert_select "input[name='purchase_order_versions[#{target.id}]'][value='0']"
        assert_equal original_order_id, @item.reload.purchase_order_id
      end
    end
  end
end
