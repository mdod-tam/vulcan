# frozen_string_literal: true

module Admin
  class PurchaseOrderShippingRequestsController < BaseController
    before_action :load_order

    def create
      attributes = params.expect(purchase_order_shipping_request: %i[recipient_email shipping_instructions]).to_h.symbolize_keys
      request = vendor_order.send!(order: @order, attributes:, expected_version: params.expect(:expected_version))
      if request.delivery_sent?
        redirect_to_order(notice: 'PO link emailed to the vendor.')
      else
        redirect_to_order(alert: 'Vendor email failed. Send a new link or contact the vendor directly.')
      end
    rescue Equipment::Conflict, ActiveRecord::RecordInvalid => e
      flash[:vendor_shipping_input] = attributes.slice(:recipient_email).transform_values { |email| email.to_s.truncate(254) } if attributes
      anchor = @order.devices_missing_shipping_details.any? ? 'order-shipping-details' : 'vendor-shipping'
      redirect_to_order(anchor:, alert: e.is_a?(ActiveRecord::RecordInvalid) ? e.record.errors.full_messages.to_sentence : e.message)
    end

    def destroy
      vendor_order.revoke!(order: @order, request_id: params.expect(:shipping_request_id))
      redirect_to_order(notice: 'Vendor link revoked.')
    rescue Equipment::Conflict => e
      redirect_to_order(alert: e.message)
    end

    private

    def load_order
      @order = PurchaseOrder.find(params.expect(:purchase_order_id))
    end

    def vendor_order
      Equipment::VendorOrder.new(actor: current_user)
    end

    def redirect_to_order(anchor: 'vendor-shipping', **flash)
      redirect_to admin_purchase_order_path(@order, anchor:), status: :see_other, **flash
    end
  end
end
