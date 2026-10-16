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

    test 'shared header review is read-only and names its full impact before confirmation' do
      assert_no_difference 'Event.count' do
        patch admin_purchase_order_correction_path(@order), params: { review: '1', purchase_order: { number: 'Reviewed Number' }, reason: 'Wrong PO reference',
                                                                      expected_version: 0, item_versions: versions }
      end
      assert_response :success
      assert_select 'h2', text: 'Review old and new header values'
      assert_select 'form[data-turbo=false] input[name=impact_token]'
      assert_select 'input[name=confirmed_impact][required]'
      assert_select 'textarea[name=reason]', text: 'Wrong PO reference'
      assert_select 'dt', text: 'PO number:', count: 1
      assert_select 'dt', count: 1
      assert_select 'dd', text: "#{@order.number} → Reviewed Number"
      assert_not_equal 'Reviewed Number', @order.reload.number
    end

    test 'forged impact confirmation cannot change a shared header' do
      assert_no_difference 'Event.count' do
        patch admin_purchase_order_correction_path(@order), params: { confirmed_impact: '1', purchase_order: { number: 'Forged Number', sent_at: '13/45/2026' }, reason: 'Wrong PO reference',
                                                                      expected_version: 0, item_versions: versions }
      end
      assert_response :unprocessable_entity
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
      @sibling.destroy!
      old_versions = { @item.id.to_s => '0' }
      @order.update!(number: 'Newer Number')
      2.times do
        assert_no_difference 'Event.count' do
          patch admin_purchase_order_correction_path(@order), params: { purchase_order: { number: 'Stale Draft' }, reason: 'Old browser tab',
                                                                        expected_version: '0', item_versions: old_versions }
        end
        assert_response :unprocessable_entity
        assert_select 'input[name=expected_version][value="0"]'
        assert_select "input[name='item_versions[#{@item.id}]'][value='0']"
        assert_equal 'Newer Number', @order.reload.number
      end
    end

    private

    def versions
      [@item, @sibling].to_h { |item| [item.id.to_s, item.lock_version.to_s] }
    end
  end
end
