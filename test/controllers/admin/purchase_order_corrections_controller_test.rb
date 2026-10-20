# frozen_string_literal: true

require 'test_helper'

module Admin
  class PurchaseOrderCorrectionsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @admin = create(:admin)
      @item = create(:equipment_item)
      @order = @item.purchase_order
      @sibling = create(:equipment_item, application: @item.application, purchase_order: @order)
      sign_in_for_integration_test(@admin)
    end

    test 'expired shared header review retains its draft until a fresh read-only review is confirmed' do
      original = @order.attributes
      original_items = [@item, @sibling].map(&:attributes)
      context = { tab: 'ordered', product_id: @item.product_id.to_s, vendor_id: @order.vendor_id.to_s }
      submitted = { purchase_order: { number: 'Reviewed Number' }, reason: 'Wrong PO reference', expected_version: 0,
                    item_versions: versions, return_context: context }
      assert_no_difference 'Event.count' do
        patch admin_purchase_order_correction_path(@order), params: submitted.merge(review: '1')
      end
      assert_response :success
      assert_select 'h2', text: 'Review old and new header values'
      assert_select '#equipment-correction-impact-heading[tabindex="-1"][autofocus]'
      assert_equal Mime[:html].to_s, response.media_type
      assert_select '#equipment-correction form input[name=impact_token]'
      assert_select '#equipment-correction form[data-turbo=false]', count: 0
      assert_select 'input[name=confirmed_impact][required]'
      assert_select 'textarea[name=reason]', text: 'Wrong PO reference'
      assert_select 'dt', text: 'PO number:', count: 1
      assert_select 'dt', count: 1
      assert_select 'dd', text: "#{@order.number} → Reviewed Number"
      assert_not_equal 'Reviewed Number', @order.reload.number

      headers = { 'Accept' => Mime[:turbo_stream].to_s }
      assert_no_difference 'Event.count' do
        patch admin_purchase_order_correction_path(@order), headers: headers, params: submitted.merge(review: '1')
      end
      assert_response :success
      assert_equal Mime[:turbo_stream].to_s, response.media_type
      assert_select 'turbo-stream[action=replace][target=equipment-correction]', count: 1 do
        assert_select 'template #equipment-correction form[action=?]', admin_purchase_order_correction_path(@order)
        assert_select 'input[name=expected_version][value="0"]'
        submitted[:item_versions].each do |id, version|
          assert_select 'input[name=?][value=?]', "item_versions[#{id}]", version
        end
        assert_select 'input[name=confirmed_impact][required]:not([checked])'
        assert_select '#equipment-correction-impact-heading[tabindex="-1"][autofocus]'
        assert_select 'button[name=review][value="1"][data-turbo-submits-with]', text: 'Review changed values'
        assert_select 'input[type=submit][data-turbo-submits-with][value="Save purchase order correction"]'
        assert_select 'form[data-turbo=false]', count: 0
      end
      token = css_select('input[name=impact_token]').sole['value']
      assert token.present?

      travel 31.minutes do
        assert_no_difference ['Event.count', 'EquipmentItem.count', 'PurchaseOrder.count'] do
          patch admin_purchase_order_correction_path(@order), headers: headers,
                                                              params: submitted.merge(reviewing: '1', confirmed_impact: '1', impact_token: token)
        end
        assert_response :unprocessable_entity
        assert_equal Mime[:html].to_s, response.media_type
        assert_select '#purchase-order-correction-errors[role=alert][tabindex="-1"][data-controller=error-summary]',
                      text: /This correction review is no longer valid\. Review the current values again before saving\./
        assert_select '#purchase_order_number[value="Reviewed Number"]'
        assert_select '#reason', text: submitted[:reason]
        assert_select '#expected_version[value="0"]'
        submitted[:item_versions].each { |id, version| assert_select 'input[name=?][value=?]', "item_versions[#{id}]", version }
        context.each { |key, value| assert_select 'input[name=?][value=?]', "return_context[#{key}]", value }
        assert_select 'input[name=impact_token], input[name=reviewing], input[name=confirmed_impact]', count: 0
        assert_select '#equipment-correction-impact-heading', count: 0
        assert_select 'button[name=review][value="1"]', text: 'Review correction'
        assert_select 'input[type=submit][value="Save purchase order correction"]', count: 0
        assert_equal original, @order.reload.attributes
        assert_equal original_items, [@item.reload, @sibling.reload].map(&:attributes)

        assert_no_difference 'Event.count' do
          patch admin_purchase_order_correction_path(@order), headers: headers, params: submitted.merge(review: '1')
        end
        assert_response :success
        assert_equal Mime[:turbo_stream].to_s, response.media_type
        assert_select '#equipment-correction-impact-heading[tabindex="-1"][autofocus]'
        assert_select 'input[name=confirmed_impact][required]:not([checked])'
        fresh_token = css_select('input[name=impact_token]').sole['value']
        assert fresh_token.present?
        assert_not_equal token, fresh_token
        assert_difference 'Event.count', 1 do
          patch admin_purchase_order_correction_path(@order), headers: headers,
                                                              params: submitted.merge(reviewing: '1', confirmed_impact: '1', impact_token: fresh_token)
        end
        assert_response :see_other
        assert_redirected_to admin_purchase_order_path(@order, return_context: context)
      end
      assert_equal 'Reviewed Number', @order.reload.number
    end

    test 'forged impact confirmation cannot change a shared header' do
      assert_no_difference 'Event.count' do
        patch admin_purchase_order_correction_path(@order), headers: { 'Accept' => Mime[:turbo_stream].to_s },
                                                            params: { confirmed_impact: '1', purchase_order: { number: 'Forged Number', sent_at: '13/45/2026' }, reason: 'Wrong PO reference',
                                                                      expected_version: 0, item_versions: versions }
      end
      assert_response :unprocessable_entity
      assert_equal Mime[:html].to_s, response.media_type
      assert_select '#equipment-correction form[data-turbo=false]', count: 0
      assert_select '#purchase-order-correction-errors[role=alert][tabindex="-1"][data-controller=error-summary]'
      assert_not_equal 'Forged Number', @order.reload.number
      assert_select 'input[name="purchase_order[number]"][value="Forged Number"]'
      assert_select '#purchase_order_sent_at[aria-invalid=true][aria-describedby="purchase_order_sent_at-help purchase_order_sent_at-error"][value="13/45/2026"]'
      assert_select '#purchase_order_sent_at-error', text: /Date PO sent is invalid/
    end

    test 'an inactive recorded vendor remains visible for historical header correction' do
      @order.vendor.update!(status: :inactive)

      get edit_admin_purchase_order_correction_path(@order)

      assert_response :success
      assert_select '#purchase_order_vendor_id option[selected][value=?]', @order.vendor_id.to_s
    end

    test 'stale header form retains original versions and unchanged retries cannot overwrite a newer correction' do
      old_versions = versions
      submitted = { purchase_order: { number: 'Stale Draft' }, reason: 'Old browser tab', expected_version: '0', item_versions: old_versions }
      headers = { 'Accept' => Mime[:turbo_stream].to_s }
      patch admin_purchase_order_correction_path(@order), headers: headers, params: submitted.merge(review: '1')
      assert_response :success
      assert_select 'turbo-stream[action=replace][target=equipment-correction] template #equipment-correction'
      token = css_select('input[name=impact_token]').sole['value']
      submitted.merge!(reviewing: '1', confirmed_impact: '1', impact_token: token)
      @order.update!(number: 'Newer Number')
      2.times do
        assert_no_difference 'Event.count' do
          patch admin_purchase_order_correction_path(@order), headers: headers, params: submitted
        end
        assert_response :unprocessable_entity
        assert_equal Mime[:html].to_s, response.media_type
        assert_select '#equipment-correction form[data-turbo=false]', count: 0
        assert_select 'input[name=expected_version][value="0"]'
        assert_select "input[name='item_versions[#{@item.id}]'][value='0']"
        assert_select 'input[name=impact_token][value=?]', token
        assert_select 'input[name=confirmed_impact]:not([checked])'
        assert_select '#equipment-correction-impact-heading[autofocus]', count: 0
        assert_select 'input[name="purchase_order[number]"][value="Stale Draft"]'
        assert_equal 'Newer Number', @order.reload.number
      end
    end

    private

    def versions
      [@item, @sibling].to_h { |item| [item.id.to_s, item.lock_version.to_s] }
    end
  end
end
