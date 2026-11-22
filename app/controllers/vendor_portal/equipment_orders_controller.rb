# frozen_string_literal: true

module VendorPortal
  class EquipmentOrdersController < SecurePublicFormController
    layout 'secure_public'

    before_action { response.headers['X-Robots-Tag'] = 'noindex, nofollow' }
    before_action :load_shipping_request
    around_action { |_, action| I18n.with_locale(:en, &action) }

    def show
      load_destinations
    end

    def update
      @shipment = params.expect(shipment: [:destination, :carrier, :tracking_number, :shipped_at, { item_ids: [], versions: {} }])
      rows = Array(@shipment[:item_ids]).map { |id| { id: id, lock_version: @shipment.dig(:versions, id) } }
      Equipment::Shipment.new(vendor_request: @shipping_request).call(rows:, attributes: @shipment)
      redirect_to secure_vendor_order_path(token: @token), notice: 'Tracking saved.', status: :see_other
    rescue Equipment::Conflict, ActiveRecord::RecordInvalid => e
      return render_unavailable unless @shipping_request.reload.active_for_public_use?

      @shipment.delete(:item_ids) if e.is_a?(Equipment::Shipment::SelectionChanged)
      @error = e.is_a?(ActiveRecord::RecordInvalid) ? e.record.errors.full_messages.to_sentence : e.message
      load_destinations
      render :show, status: :unprocessable_content
    end

    private

    def load_shipping_request
      @token = params[:token]
      @shipping_request = PurchaseOrderShippingRequest.from_public_token(@token)
      return render_unavailable unless @shipping_request&.active_for_public_use?

      @order = @shipping_request.purchase_order
    end

    def load_destinations
      items = @order.equipment_items.active.direct_vendor.includes(:product, application: :user).order(:id)
      groups = items.select { |item| item.application&.status_approved? }.group_by { |item| [item.application.user_id, item.shipping_snapshot] }
      @destinations = groups.values.map do |units|
        first = units.first
        shipped, remaining = units.partition(&:shipped_at?)
        { first: first, shipped: shipped, remaining: remaining, draft: (@shipment if @shipment&.[](:destination) == first.id.to_s) }
      end
    end
  end
end
