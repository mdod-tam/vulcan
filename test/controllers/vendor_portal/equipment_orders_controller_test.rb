# frozen_string_literal: true

require 'test_helper'

module VendorPortal
  class EquipmentOrdersControllerTest < ActionDispatch::IntegrationTest
    setup do
      @system = ensure_system_audit_actor!
      @admin = create(:admin)
      @order = create(:purchase_order, vendor_name: 'Test supplier', sent_at: nil)
      @first = create(:equipment_item, purchase_order: @order, shipping_address_1: '100 Vendor Test Ave')
      @second = create(:equipment_item, purchase_order: @order, application: @first.application, shipping_address_1: @first.shipping_address_1)
      @other = create(:equipment_item, shipping_address_1: '200 Private Test Ave')
    end

    test 'staff release the PO and a vendor can add partial shipments and safely retry' do
      assert_nil @order.sent_at
      path = send_order_link
      sign_out
      get path
      assert_response :success
      assert_includes response.headers.fetch('Cache-Control'), 'no-store'
      assert_equal 'no-referrer', response.headers['Referrer-Policy']
      assert_select 'h1', "Purchase order #{@order.number}"
      assert_includes response.body, @first.shipping_address_1
      assert_not_includes response.body, @other.shipping_address_1
      assert_not_includes response.body, @first.application.user.email

      first_package = shipment(@first)
      mail = capture_emails do
        assert_difference('Event.where(action: "equipment_shipment_recorded").count', 1) { patch path, params: first_package }
        assert_redirected_to path
        assert_no_difference(['Event.count', 'Notification.count']) { patch path, params: first_package }
        assert_redirected_to path
      end.sole
      assert_equal [@first.application.user.email], mail.to
      assert_equal 'Your MAT equipment is on its way', mail.subject
      assert_includes mail.text_part.body.decoded, 'Tracking number — FIRST-PACKAGE (UPS)'
      link = Nokogiri::HTML(mail.html_part.body.decoded).at_css('a')
      assert_equal 'FIRST-PACKAGE', link.text
      assert_equal 'https://www.ups.com/track?loc=en_US&tracknum=FIRST-PACKAGE', link['href']
      assert_equal 'FIRST-PACKAGE', @first.reload.tracking_number
      assert_nil @second.reload.shipped_at
      event = @first.events.find_by!(action: 'equipment_shipment_recorded')
      assert_equal @system, event.user
      assert_equal @order.shipping_requests.sole.id, event.metadata.fetch('purchase_order_shipping_request_id')

      assert_emails(1) { patch path, params: shipment(@second, tracking: 'SECOND-PACKAGE') }
      assert_redirected_to path
      follow_redirect!
      assert_select 'h3', 'Recorded shipments'
      assert_select 'input[name="shipment[item_ids][]"]', count: 0
      assert_equal 'SECOND-PACKAGE', @second.reload.tracking_number
    end

    test 'a vendor link rejects foreign units and stale edits and can be revoked' do
      path = send_order_link
      sign_out

      assert_no_enqueued_emails { patch path, params: shipment(@other) }
      assert_response :unprocessable_content
      assert_nil @other.reload.shipped_at

      assert_no_enqueued_emails { patch path, params: shipment(@first, date: '02/30/2026') }
      assert_response :unprocessable_content
      assert_select 'input[name="shipment[tracking_number]"][value="FIRST-PACKAGE"]'
      assert_select 'input[name="shipment[item_ids][]"][checked]'

      stale = shipment(@first)
      @first.update!(shipping_address_1: '300 Corrected Test Ave')
      patch path, params: stale
      assert_response :unprocessable_content
      assert_select 'input[name="shipment[item_ids][]"][checked]', count: 0
      assert_nil @first.reload.shipped_at

      sign_in_as(@admin, bypass_mfa_enrollment: true)
      request = @order.shipping_requests.sole
      delete admin_purchase_order_shipping_request_path(@order), params: { shipping_request_id: request.id }
      assert_redirected_to admin_purchase_order_path(@order, anchor: 'vendor-shipping')
      sign_out
      get path
      assert_select 'h1', 'Purchase order link unavailable'
      assert_not_includes response.body, @first.shipping_address_1
      patch path, params: shipment(@first)
      assert_nil @first.reload.shipped_at
    end

    test 'sending a PO refuses incomplete shipping details and links staff to the device' do
      sign_in_as(@admin, bypass_mfa_enrollment: true)
      patch admin_equipment_item_path(@first), params: {
        equipment_item: { shipping_zip_code: '' }, expected_version: @first.lock_version, reason: 'Confirm ZIP with recipient'
      }
      assert_response :see_other
      assert_not @first.reload.shipping_ready?
      assert_no_emails { post admin_purchase_order_shipping_request_path(@order), params: send_parameters }
      assert_redirected_to admin_purchase_order_path(@order, anchor: 'order-shipping-details')
      assert_nil @order.reload.sent_at
      assert_empty @order.shipping_requests
      follow_redirect!
      assert_select '#order-shipping-details a[href=?]', edit_admin_equipment_item_path(@first)

      patch send_order_admin_purchase_order_path(@order), params: { sent_at: Date.current, expected_version: @order.lock_version }
      assert_nil @order.reload.sent_at
      assert_match(/Confirm the shipping address and setup/, flash[:alert])

      @first.update!(shipping_zip_code: '21201')
      send_order_link
      patch admin_equipment_item_path(@first), params: {
        equipment_item: { shipping_address_1: '400 Corrected Test Ave' }, expected_version: @first.lock_version, reason: 'Confirm new address'
      }
      assert_response :see_other
      assert_match(/Contact the vendor to confirm the new shipping address/, flash[:notice])
    end

    test 'a failed first email leaves the PO unsent and allows another attempt' do
      sign_in_as(@admin, bypass_mfa_enrollment: true)
      EmailDelivery.stubs(:deliver_now!).raises(Timeout::Error)
      post admin_purchase_order_shipping_request_path(@order), params: send_parameters

      assert_redirected_to admin_purchase_order_path(@order, anchor: 'vendor-shipping')
      assert_nil @order.reload.sent_at
      assert_predicate @order.shipping_requests.sole, :delivery_failed?
      assert_predicate @order.shipping_requests.sole, :revoked?
      assert_match(/email failed/, flash[:alert])
    end

    private

    def send_order_link
      sign_in_as(@admin, bypass_mfa_enrollment: true)
      assert_emails 1 do
        post admin_purchase_order_shipping_request_path(@order), params: send_parameters
      end
      assert_redirected_to admin_purchase_order_path(@order, anchor: 'vendor-shipping')
      assert_equal Date.current, @order.reload.sent_at
      mail = ActionMailer::Base.deliveries.last
      assert_equal ['orders@example.test'], mail.to
      assert_not_includes mail.body.decoded, @first.shipping_address_1
      URI.parse(mail.body.decoded.lines.find { |line| line.start_with?('http') }.strip).request_uri
    end

    def send_parameters
      { expected_version: @order.lock_version, purchase_order_shipping_request: { recipient_email: 'orders@example.test' } }
    end

    def shipment(item, tracking: 'FIRST-PACKAGE', date: Date.current.iso8601)
      { shipment: { destination: item.id, item_ids: [item.id], versions: { item.id.to_s => item.lock_version },
                    tracking_number: tracking, carrier: 'ups', shipped_at: date } }
    end
  end
end
