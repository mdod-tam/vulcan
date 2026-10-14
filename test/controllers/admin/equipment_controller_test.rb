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
      assert_select 'a[aria-current=page].bg-indigo-700', text: 'Needs Ordering'
      assert_select 'label', text: /Select group:\s*#{Regexp.escape(@product.manufacturer)}.*#{Regexp.escape(@product.name)}/
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
      assert_select 'section[data-equipment-selection-target=group] p', text: /1 unit across\s+1 application/
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

    test 'earlier review lists only eligible undecided PO and tracking facts and preserves return context' do
      bids = create(:application, :approved, :with_all_proofs, equipment_bids_sent_at: 2.days.ago)
      po = create(:application, :approved, :with_all_proofs, equipment_po_sent_at: 2.days.ago)
      tracking = create(:application, :approved, :with_all_proofs, equipment_tracking_number: 'EarlierPackage')
      archived = create(:application, :approved, :with_all_proofs, equipment_po_sent_at: 2.days.ago)
      archived.transition_status!(:archived, actor: @admin)
      rejected = create(:application, :rejected, equipment_po_sent_at: 2.days.ago)
      decided = create(:application, :approved, :with_all_proofs, equipment_po_sent_at: 2.days.ago)
      EquipmentNeeds::Writer.update!(decided, rows: [], expected_initialized_at: '', actor: @admin, reason: 'Delivered before this system')
      voucher = create(:application, :approved, :with_all_proofs, :voucher_fulfillment, equipment_bids_sent_at: 2.days.ago)
      blank = create(:application, :approved, :with_all_proofs, equipment_tracking_number: " \t\n")
      mapped = create(:application, :approved, :with_all_proofs, equipment_po_sent_at: 2.days.ago)
      create(:equipment_item, application: mapped, purchase_order: nil, withdrawn_at: Time.current)
      context = { tab: 'ordered', product_id: @product.id.to_s, vendor_id: @vendor.id.to_s }

      get admin_equipment_index_path(context)

      assert_response :success
      assert_select '#equipment-legacy-review' do
        assert_select 'h2', text: 'Earlier fulfillment details need review'
        assert_select 'p', text: /Confirm what still needs ordering in the needs editor/
        [po, tracking].each do |application|
          assert application.equipment_legacy_review?
          assert_select 'a[href=?]', admin_application_path(application, anchor: 'equipment', return_context: context)
        end
        [bids, archived, rejected, decided, voucher, blank, mapped].each do |application|
          assert_not application.equipment_legacy_review?
          assert_select 'a', text: "Application ##{application.id}", count: 0
        end
      end
    end
  end
end
