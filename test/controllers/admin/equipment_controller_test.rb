# frozen_string_literal: true

require 'test_helper'
require 'csv'

module Admin
  class EquipmentControllerTest < ActionDispatch::IntegrationTest
    setup do
      @admin = create(:admin)
      sign_in_for_integration_test(@admin)
      @vendor = create(:vendor)
      @product = create(:product, name: '=Unsafe model', manufacturer: '+Unsafe maker')
      @product.vendors << @vendor
      @need = create(:equipment_need, product: @product, remaining_quantity: 2)
      @detached = create(:equipment_item, application: @need.application, product: @product, purchase_order: nil, tracking_number: 'PRIVATE-ID')
    end

    test 'queue groups exact catalog identities and distinguishes new units from detached records' do
      get admin_equipment_index_path(vendor_id: @vendor.id)
      assert_response :success
      assert_select 'section[data-equipment-selection-target=group]', count: 1
      assert_select 'section[data-equipment-selection-target=group] p', text: /3 units across\s+1 application/
      assert_includes response.body, '2 new devices still needed'
      assert_includes response.body, 'Previously ordered device awaiting reorder'
      assert_select "a[href*='#{edit_admin_equipment_item_path(@detached)}']"
    end

    test 'selected export combines quantities and excludes device and recipient identity' do
      other = create(:equipment_need)
      get admin_equipment_index_path(format: :csv, need_ids: [@need.id], item_ids: [@detached.id])
      assert_response :success
      records = CSV.parse(response.body, headers: true)
      assert_equal 1, records.size
      assert_equal '3', records.sole['Required quantity']
      assert_equal "'+Unsafe maker", records.sole['Manufacturer']
      assert_equal "'=Unsafe model", records.sole['Catalog model']
      assert_not_includes response.body, 'PRIVATE-ID'
      assert_not_includes response.body, @need.application.user.email
      assert_not_includes response.body, other.product.name
    end

    test 'unselected export uses current product and carrying-vendor filters' do
      create(:equipment_need)
      get admin_equipment_index_path(format: :csv, vendor_id: @vendor.id, product_id: @product.id)
      assert_equal '3', CSV.parse(response.body, headers: true).sole['Required quantity']
    end

    test 'one stale explicit selection prevents a partial export or review' do
      get admin_equipment_index_path(format: :csv, need_ids: [@need.id, '999999999'])
      assert_response :redirect
      get new_admin_purchase_order_path(need_ids: [@need.id, '999999999'])
      assert_response :redirect
      assert_match(/no longer available/, flash[:alert])
    end

    test 'ordered and shipped tabs follow actual ship date rather than tracking' do
      ordered = create(:equipment_item, product: @product, tracking_number: 'ORDERED-TRACK')
      shipped = create(:equipment_item, product: @product, shipped_at: Date.current, tracking_number: 'SHIPPED-TRACK')
      get admin_equipment_index_path(tab: 'shipped')
      assert_includes response.body, 'SHIPPED-TRACK'
      assert_not_includes response.body, 'ORDERED-TRACK'
      get admin_equipment_index_path(tab: 'ordered')
      assert_includes response.body, 'ORDERED-TRACK'
      assert_not_includes response.body, 'SHIPPED-TRACK'
      assert_equal 'ordered', ordered.queue_status
      assert_equal 'shipped', shipped.queue_status
    end

    test 'vendor access cannot list equipment or download bid exports' do
      sign_in_for_integration_test(@vendor)
      get admin_equipment_index_path(format: :csv)
      assert_redirected_to root_path
    end
  end
end
