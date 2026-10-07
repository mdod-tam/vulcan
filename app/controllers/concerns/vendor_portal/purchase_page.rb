# frozen_string_literal: true

module VendorPortal
  # The purchase page and the fulfillment actions that re-render it. A purchase is found only among
  # the signed-in vendor's own, so another vendor's purchase is not found at all.
  module PurchasePage
    extend ActiveSupport::Concern

    STALE_MESSAGE = 'Someone else changed this purchase while you were editing. Review it below and try again.'
    NOT_FULFILLABLE_MESSAGE = 'Only a completed purchase can have shipping details.'

    private

    def load_purchase(id)
      @transaction = current_user.voucher_transactions.includes(:shipments, :products, voucher: { application: :user }).find(id)
    end

    # expected_version is the purchase version the vendor's add-package form was built from.
    def render_purchase_page(status: :ok, new_shipment: nil, expected_version: nil)
      @new_shipment = new_shipment || VoucherTransactionShipment.new
      @expected_version = expected_version || @transaction.fulfillment_version
      render 'vendor_portal/transactions/show', status: status
    end

    def fulfillment_service
      VoucherTransactions::FulfillmentService.new(transaction: @transaction, actor: current_user)
    end

    def redirect_to_purchase(notice: nil, alert: nil)
      redirect_to vendor_portal_transaction_path(@transaction), notice: notice, alert: alert
    end
  end
end
