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
      assert_select 'dd', text: /#{Regexp.escape(@order.vendor.business_name)}\s*→\s*#{Regexp.escape(@order.vendor.business_name)}/
      assert_not_equal 'Reviewed Number', @order.reload.number
    end

    test 'forged impact confirmation cannot change a shared header' do
      assert_no_difference 'Event.count' do
        patch admin_purchase_order_correction_path(@order), params: { confirmed_impact: '1', purchase_order: { number: 'Forged Number' }, reason: 'Wrong PO reference',
                                                                      expected_version: 0, item_versions: versions }
      end
      assert_response :unprocessable_entity
      assert_not_equal 'Forged Number', @order.reload.number
      assert_select 'input[name="purchase_order[number]"][value="Forged Number"]'
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
