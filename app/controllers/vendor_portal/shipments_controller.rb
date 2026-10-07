# frozen_string_literal: true

module VendorPortal
  # Packages for one of the vendor's purchases. VoucherTransactions::FulfillmentService does the writing.
  class ShipmentsController < BaseController
    include PurchasePage

    before_action { load_purchase(params[:transaction_id]) }

    def create
      was_pickup = @transaction.fulfillment_local_pickup?
      fulfillment_service.add_shipment!(attributes: shipment_params, expected_version: params.require(:fulfillment_version))
      notice = 'Tracking number saved.'
      notice += ' This purchase is now marked as shipping instead of local pickup.' if was_pickup
      redirect_to_purchase(notice: notice)
    rescue ActiveRecord::RecordInvalid => e
      render_purchase_page(status: :unprocessable_content, new_shipment: e.record, expected_version: params[:fulfillment_version])
    rescue VoucherTransactions::FulfillmentService::StaleError
      redirect_to_purchase(alert: STALE_MESSAGE)
    rescue VoucherTransactions::FulfillmentService::NotFulfillableError
      redirect_to_purchase(alert: NOT_FULFILLABLE_MESSAGE)
    end

    def update
      fulfillment_service.correct_shipment!(shipment_id: params[:id], attributes: shipment_params,
                                            expected_lock_version: params.require(:shipment).require(:lock_version))
      redirect_to_purchase(notice: 'Package updated.')
    rescue ActiveRecord::RecordInvalid => e
      @invalid_correction = e.record
      render_purchase_page(status: :unprocessable_content)
    rescue VoucherTransactions::FulfillmentService::StaleError
      redirect_to_purchase(alert: STALE_MESSAGE)
    rescue VoucherTransactions::FulfillmentService::NotFulfillableError
      redirect_to_purchase(alert: NOT_FULFILLABLE_MESSAGE)
    end

    private

    def shipment_params
      params.expect(shipment: [*VoucherTransactions::FulfillmentService::SHIPMENT_FIELDS])
    end
  end
end
