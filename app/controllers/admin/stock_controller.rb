# frozen_string_literal: true

module Admin
  class StockController < BaseController
    def index
      @products = Product.model_confirmed.ordered_by_name
      @products = @products.where(id: params[:product_id]) if params[:product_id].present?
      @available_counts = equipment_navigation_summary.available_counts
      @reserved_counts = equipment_navigation_summary.reserved_counts
      @incoming_counts = equipment_navigation_summary.incoming_counts
      @open_bids = BidGroup.open.program_stock.count
      @unsent_orders = PurchaseOrder.program_stock.ready_to_send.count
      @awaiting_receipt = PurchaseOrder.program_stock.where.not(sent_at: nil).joins(:equipment_items).merge(EquipmentItem.active.where(stock_received_on: nil)).distinct
      scope = EquipmentItem.active.stock.includes(:product)
      scope = scope.where(product_id: params[:product_id]) if params[:product_id].present?
      @units = scope.order(:stock_received_on, :id)
    end

    def new
      @products = Product.model_confirmed.ordered_by_name
      @operation_id = SecureRandom.uuid
    end

    def create
      data = params.expect(stock: %i[product_id quantity received_on provenance operation_id])
      @operation_id = data[:operation_id]
      Equipment::StockReceipt.new(actor: current_user).existing!(product: Product.find(data[:product_id]), quantity: data[:quantity], received_on: data[:received_on],
                                                                 provenance: data[:provenance], operation_id: @operation_id)
      redirect_to admin_stock_index_path, notice: 'Existing on-hand stock recorded.', status: :see_other
    rescue Equipment::Conflict, ActiveRecord::RecordInvalid => e
      @form_errors = [e.message]
      @products = Product.model_confirmed.ordered_by_name
      render :new, status: :unprocessable_content
    end
  end
end
