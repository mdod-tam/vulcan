# frozen_string_literal: true

require 'test_helper'

module Admin
  class EquipmentItemsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @admin = create(:admin)
      @item = create(:equipment_item)
      sign_in_for_integration_test(@admin, bypass_mfa_enrollment: true)
    end

    test 'blank optional shipping fields do not add unchanged details to a tracking correction review' do
      @item.update!(shipped_at: Date.current, tracking_number: 'Original')
      attributes = @item.shipping_snapshot.transform_values { |value| value || '' }.merge('tracking_number' => 'Corrected')
      assert_no_difference 'Event.count' do
        patch admin_equipment_item_path(@item), params: {
          review: '1', expected_version: @item.lock_version, reason: 'Correct the parcel reference', equipment_item: attributes
        }
      end
      assert_response :success
      assert_select '.bg-warning-50 th[scope=row]', count: 1, text: 'Tracking number'
      assert_nil @item.reload.shipping_care_of
      assert_nil @item.shipping_address_2
    end

    test 'shipment history filters and records a delivery with an audited receipt date' do
      @item.update!(shipped_at: Date.current, tracking_number: 'SHIPPED')
      delivered = create(:equipment_item, shipped_at: Date.current, tracking_number: 'DELIVERED', delivered_on: Date.current)
      context = { tab: 'shipped', delivery: 'awaiting' }
      get admin_equipment_index_path(context)
      assert_select 'nav[aria-label="Shipment history filters"] a[aria-current=page]', text: 'Awaiting delivery'
      assert_select "#equipment-item-#{@item.id} summary", text: 'Record delivery'
      assert_select "#equipment-item-#{delivered.id}", count: 0

      params = { expected_version: @item.lock_version, return_context: context }
      patch record_delivery_admin_equipment_item_path(@item), params: params.merge(delivered_on: Date.yesterday.iso8601)
      assert_redirected_to admin_equipment_index_path(context.merge(anchor: "equipment-item-#{@item.id}"))
      follow_redirect!
      assert_select "#equipment-item-#{@item.id} details[open] input[name=delivered_on][value=?]", Date.yesterday.iso8601
      assert_nil @item.reload.delivered_on

      patch record_delivery_admin_equipment_item_path(@item), params: params.merge(delivered_on: Date.current.iso8601)
      assert_redirected_to admin_equipment_index_path(context)
      assert_equal Date.current, @item.reload.delivered_on
      event = @item.events.find_by!(action: 'icc_financial_evidence_updated')
      assert_equal @admin, event.user
      assert_nil event.metadata.dig('before', 'delivered_on')
      assert_equal Date.current.iso8601, event.metadata.dig('after', 'delivered_on')
      follow_redirect!
      assert_select "#equipment-item-#{@item.id}", count: 0
      get admin_equipment_index_path(tab: 'shipped')
      assert_select "#equipment-item-#{@item.id}", text: /Date received/
    end

    test 'a carrier-only correction can email the new tracking link' do
      date = Date.current.iso8601
      assert_emails 1 do
        rows = [{ id: @item.id, lock_version: @item.lock_version }]
        attributes = { shipped_at: date, carrier: 'ups', tracking_number: 'SAME-PACKAGE' }
        Equipment::Shipment.new(actor: @admin).call(rows:, attributes:)
      end
      submitted = { equipment_item: { carrier: 'fedex' }, expected_version: @item.reload.lock_version, reason: 'Correct the carrier' }
      patch admin_equipment_item_path(@item), params: submitted.merge(review: '1')
      assert_response :success
      assert_select 'label[for=notify_tracking]', text: 'Email updated tracking'
      token = css_select('input[name=impact_token]').sole['value']

      mail = capture_emails do
        patch admin_equipment_item_path(@item), params: submitted.merge(impact_token: token, confirmed_impact: '1', notify_tracking: '1')
        assert_response :see_other
      end.sole
      assert_includes mail.text_part.body.decoded, 'Tracking number — SAME-PACKAGE (FedEx)'
      assert_equal 'fedex', @item.reload.carrier
    end

    test 'item forms and writes require an administrator' do
      sign_in_for_integration_test(create(:evaluator), bypass_mfa_enrollment: true)
      get edit_admin_equipment_item_path(@item)
      assert_redirected_to root_path
      assert_no_difference 'Event.count' do
        patch admin_equipment_item_path(@item), headers: { 'Accept' => Mime[:turbo_stream].to_s },
                                                params: { equipment_item: { tracking_number: 'Blocked' }, expected_version: 0, reason: 'Unauthorized' }
      end
      assert_redirected_to root_path
      assert_nil @item.reload.tracking_number
      patch record_delivery_admin_equipment_item_path(@item), params: { delivered_on: Date.current, expected_version: @item.lock_version }
      assert_redirected_to root_path
    end

    test 'device editor shows linked shared history without another device unrelated events' do
      other = create(:equipment_item)
      shared = Equipment::Mutation.audit!(other, actor: @admin, action: 'equipment_stock_swapped',
                                                 changes: { replaced_unit_id: [@item.id, other.id] },
                                                 equipment_item_ids: [@item.id, other.id], reason: 'Shared replacement history')
      unrelated = Equipment::Mutation.audit!(other, actor: @admin, action: 'equipment_item_corrected',
                                                    changes: { carrier: [nil, 'ups'] }, reason: 'Unrelated device history')
      get edit_admin_equipment_item_path(@item)
      assert_response :success
      assert_select 'details', text: /Shared replacement history/
      assert_select 'details', text: /Unrelated device history/, count: 0
      assert_includes @item.equipment_history, shared
      assert_not_includes @item.equipment_history, unrelated
    end

    test 'invalid shipment re-renders every entered field and validated return context' do
      patch admin_equipment_item_path(@item), headers: { 'Accept' => Mime[:turbo_stream].to_s }, params: {
        equipment_item: { product_id: @item.product_id, shipped_at: '13/45/2026',
                          tracking_number: 'RetryPackage', carrier: 'fedex', serial_number: 'RetrySerial', imei: '123456789012345' },
        expected_version: 0, reason: 'Record shipment', return_context: { tab: 'ordered', product_id: @item.product_id }
      }
      assert_response :unprocessable_entity
      assert_equal Mime[:html].to_s, response.media_type
      assert_select '#equipment-correction form[data-turbo=false]', count: 0
      assert_select '#equipment-item-errors[role=alert][tabindex="-1"][data-controller=error-summary]'
      assert_select '#equipment-item-errors li', text: /Date shipped is invalid/
      assert_select 'input[name="equipment_item[shipped_at]"][value="13/45/2026"]'
      assert_select '#equipment_item_shipped_at[aria-invalid=true][aria-describedby="equipment-ship-date-error"]'
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
      original_label = @item.product.catalog_label
      replacement_label = replacement.catalog_label
      assert_response :success
      assert_equal Mime[:html].to_s, response.media_type
      assert_select '#equipment-correction form input[name=impact_token]'
      assert_select '#equipment-correction form[data-turbo=false]', count: 0
      assert_select '#equipment-correction-impact-heading', text: 'Changes'
      assert_select '.bg-warning-50 th[scope=col]', text: 'Before'
      assert_select '.bg-warning-50 th[scope=col]', text: 'After'
      rows = css_select('.bg-warning-50 tbody tr').map { |row| row.css('th, td').map(&:text) }
      assert_includes rows, ['Product', original_label, replacement_label]
      assert_includes rows, ['Date shipped', 'No value', Date.current.strftime('%m/%d/%Y')]
      assert_includes rows, ['Carrier', 'No value', 'USPS']
      assert_includes rows, ['IMEI (15 digits)', 'No value', '123456789012345']
      assert_equal 4, rows.size
    end

    test 'identity conflict links are available only in the authorized correction form' do
      conflict = create(:equipment_item, imei: '123456789012345')
      context = { tab: 'ordered', product_id: @item.product_id.to_s }
      patch admin_equipment_item_path(@item), params: { equipment_item: { imei: '123456789012345' }, expected_version: 0, reason: 'Identify device', return_context: context }
      assert_response :unprocessable_entity
      assert_select 'a[href=?]', edit_admin_equipment_item_path(conflict, return_context: context), text: "Review device ##{conflict.id}"
      assert_select '[role=alert]', text: /IMEI/
      assert_nil @item.reload.imei
    end

    test 'reorder and cancellation use their own form for eligible unshipped devices' do
      get edit_admin_equipment_item_path(@item)
      assert_select '#equipment_item_purchase_order_id', count: 0
      assert_select 'select[name=operation]', count: 0
      assert_select '#equipment-disposition form' do
        assert_select 'input[name=operation][value=detach]'
        assert_select '[name^=equipment_item]', count: 0
        assert_select 'input[type=submit][data-turbo-confirm][value="Remove from PO for reorder"]'
      end

      submitted = { operation: 'detach', expected_version: @item.lock_version, return_context: { tab: 'ordered' } }
      assert_no_difference 'Event.count' do
        patch admin_equipment_item_path(@item), params: submitted.merge(reason: '')
      end
      assert_response :unprocessable_entity
      assert_select '#equipment-item-errors', text: /Provide a brief reason/
      assert_select '#equipment-disposition[open] input[name=expected_version][value=?]', @item.lock_version.to_s
      assert_select '#equipment-disposition input[name="return_context[tab]"][value=ordered]'

      assert_no_difference 'Event.count' do
        patch admin_equipment_item_path(@item), params: submitted.merge(reason: 'Await a replacement order', expected_version: '-1')
      end
      assert_response :unprocessable_entity
      assert_select '#equipment-disposition[open] textarea', text: 'Await a replacement order'
      assert_select '#equipment-disposition input[name=expected_version][value="-1"]'
      assert_select '#reason', text: ''

      patch admin_equipment_item_path(@item), params: submitted.merge(reason: 'Await a replacement order')
      assert_redirected_to admin_equipment_index_path(tab: 'ordered')
      assert_nil @item.reload.purchase_order_id
      get edit_admin_equipment_item_path(@item)
      assert_select '#equipment_item_purchase_order_id', count: 0
      assert_select '#equipment-disposition input[name=operation][value=withdraw]'
      assert_includes response.body, 'Assign purchase orders through a bid award.'

      patch admin_equipment_item_path(@item), params: { operation: 'withdraw', expected_version: @item.lock_version, reason: 'Request cancelled' }
      assert_redirected_to admin_application_path(@item.application, anchor: "equipment-item-#{@item.id}")
      assert_predicate @item.reload, :withdrawn_at?
    end

    test 'expired shipment review retains its draft and filters until a fresh review is confirmed' do
      @item.update!(shipped_at: Date.current, tracking_number: 'OriginalPackage')
      original = @item.attributes
      context = { tab: 'shipped', product_id: @item.product_id.to_s }
      submitted = { equipment_item: { shipped_at: Date.current.iso8601, tracking_number: 'Package' }, operation: 'update',
                    expected_version: @item.lock_version, reason: 'Record actual shipment', return_context: context }
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
        assert_select '#equipment-correction-impact-heading[tabindex="-1"][autofocus]'
        assert_select '#equipment-disposition, select[name=operation]', count: 0
        assert_select '.bg-warning-50 p', text: /Shipped devices affected/, count: 0
        assert_select 'button[name=back_to_edit][value="1"][formnovalidate]', text: 'Back to edit'
        assert_select 'button[name=confirmed_impact][value="1"][data-turbo-submits-with]', text: 'Save correction'
        assert_select 'input[type=checkbox]', count: 1
        assert_select 'input[type=checkbox][name=notify_tracking][value="1"]:not([checked])'
        assert_select 'input[type=hidden][name="equipment_item[tracking_number]"][value=Package]'
        assert_select 'input[type=text], textarea, select', count: 0
        assert_select 'a', text: 'Reload latest record', count: 0
        assert_select 'form[data-turbo=false]', count: 0
      end
      token = css_select('input[name=impact_token]').sole['value']
      assert token.present?

      assert_no_difference 'Event.count' do
        patch admin_equipment_item_path(@item), headers: headers,
                                                params: submitted.merge(equipment_item: { tracking_number: 'ChangedAfterReview' },
                                                                        reviewing: '1', confirmed_impact: '1', impact_token: token)
      end
      assert_response :unprocessable_entity
      assert_select '#equipment-item-errors', text: /Review the current correction values/
      assert_select '#equipment_item_tracking_number[value=ChangedAfterReview]'
      assert_select 'input[name=impact_token]', count: 0
      assert_equal original, @item.reload.attributes

      travel 31.minutes do
        sign_in_for_integration_test(@admin, bypass_mfa_enrollment: true)
        assert_no_difference ['Event.count', 'EquipmentItem.count', 'PurchaseOrder.count'] do
          patch admin_equipment_item_path(@item), headers: headers,
                                                  params: submitted.merge(reviewing: '1', confirmed_impact: '1', impact_token: token)
        end
        assert_response :unprocessable_entity
        assert_equal Mime[:html].to_s, response.media_type
        assert_select '#equipment-item-errors[role=alert][tabindex="-1"][data-controller=error-summary]',
                      text: /This correction review is no longer valid\. Review the current values again before saving\./
        assert_select '#equipment_item_tracking_number[value=Package]'
        assert_select '#equipment_item_shipped_at[value=?]', @item.shipped_at.strftime('%m/%d/%Y')
        assert_select '#reason', text: submitted[:reason]
        assert_select '#expected_version[value=?]', submitted[:expected_version].to_s
        context.each { |key, value| assert_select 'input[name=?][value=?]', "return_context[#{key}]", value }
        assert_select 'input[name=impact_token], input[name=reviewing], input[name=confirmed_impact]', count: 0
        assert_select '#equipment-correction-impact-heading', count: 0
        assert_select 'button[name=review][value="1"]', text: 'Review correction'
        assert_select 'button[name=confirmed_impact]', count: 0
        assert_equal original, @item.reload.attributes

        assert_no_difference 'Event.count' do
          patch admin_equipment_item_path(@item), headers: headers, params: submitted.merge(review: '1')
        end
        assert_response :success
        assert_equal Mime[:turbo_stream].to_s, response.media_type
        assert_select '#equipment-correction-impact-heading[tabindex="-1"][autofocus]'
        assert_select 'button[name=confirmed_impact][value="1"]', text: 'Save correction'
        fresh_token = css_select('input[name=impact_token]').sole['value']
        assert fresh_token.present?
        assert_not_equal token, fresh_token
        mail = capture_emails do
          assert_difference 'Event.count', 1 do
            patch admin_equipment_item_path(@item), headers: headers,
                                                    params: submitted.merge(reviewing: '1', confirmed_impact: '1', impact_token: fresh_token, notify_tracking: '1')
          end
        end.sole
        assert_equal 'Updated tracking for your MAT equipment', mail.subject
        assert_includes mail.text_part.body.decoded.lines.map(&:strip), 'Tracking number — Package'
        assert_response :see_other
        assert_redirected_to admin_equipment_index_path(context)
      end
      assert_equal Date.current, @item.reload.shipped_at
      assert_equal 'Package', @item.tracking_number
    end

    test 'mixed detach edits retain the rejected draft until details are saved separately' do
      original = @item.attributes
      context = { tab: 'ordered', product_id: @item.product_id.to_s }
      submitted = {
        equipment_item: { product_id: @item.product_id.to_s,
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
        assert_select 'select[name=operation]', count: 0
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
      params = { equipment_item: { tracking_number: 'StaleDraft' }, expected_version: submitted_version, reason: 'Old browser tab' }
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
        assert_select 'input[name=impact_token], input[name=confirmed_impact]', count: 0
        assert_select 'a[href=?]', edit_admin_equipment_item_path(@item), text: 'Reload latest record'
        assert_select 'p', text: /Reloading clears your draft/
        assert_select '#equipment-correction-impact-heading[autofocus]', count: 0
        assert_select 'input[name="equipment_item[tracking_number]"][value=StaleDraft]'
        assert_equal 'OtherAdministratorPackage', @item.reload.tracking_number
      end
    end

    test 'unallocated existing stock correction has no application or ad hoc PO controls' do
      stock = Equipment::StockReceipt.new(actor: @admin).existing!(product: @item.product, quantity: 1,
                                                                   received_on: Date.current, provenance: 'Verified program shelf count').sole
      get edit_admin_equipment_item_path(stock)
      assert_response :success
      assert_select '#equipment_item_purchase_order_id, #new_purchase_order_vendor_id, #create_purchase_order', count: 0
      assert_select 'a', text: 'Program stock'
      assert_select '#equipment-disposition summary', text: 'Remove from stock'
      assert_select '#equipment-disposition input[name=operation][value=withdraw]'
      patch admin_equipment_item_path(stock), params: { equipment_item: { serial_number: 'STOCK-RECORDED' }, expected_version: stock.lock_version, reason: 'Physical identity verified' }
      assert_redirected_to admin_stock_index_path
      assert_equal 'STOCK-RECORDED', stock.reload.serial_number
      assert_nil stock.application_id
    end
  end
end
