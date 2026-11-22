# frozen_string_literal: true

module Admin
  class StockReceiptsController < BaseController
    include EquipmentFormHandling

    before_action :load_order

    def new
      @received_on = Date.current
      @rows = []
      @expected_version = @purchase_order.lock_version
      @item_versions = outstanding.to_h { |item| [item.id.to_s, item.lock_version] }
      prepare_form
    end

    def create
      data = params.expect(receipt: [:received_on, :expected_version, { item_versions: {}, rows: [[:batch, :quantity, { identifiers: [%i[serial_number imei]] }]] }])
      @rows = data[:rows].to_a.map(&:to_h)
      @received_on = data[:received_on]
      @expected_version = data[:expected_version]
      @item_versions = data[:item_versions].to_h
      Equipment::StockReceipt.new(actor: current_user).receive!(order: @purchase_order, received_on: @received_on, rows: @rows,
                                                                expected_version: @expected_version, item_versions: @item_versions)
      redirect_to admin_purchase_order_path(@purchase_order), notice: 'Stock receipt recorded. Review received and outstanding quantities below.', status: :see_other
    rescue Equipment::Conflict, ActiveRecord::RecordInvalid => e
      @form_errors = equipment_form_errors(e)
      @purchase_order.reload
      @expected_version = @purchase_order.lock_version
      @item_versions = outstanding.to_h { |item| [item.id.to_s, item.lock_version] }
      prepare_form
      render :new, status: :unprocessable_content
    end

    private

    def load_order
      @purchase_order = PurchaseOrder.find(params.expect(:purchase_order_id))
      raise ActiveRecord::RecordNotFound unless @purchase_order.program_stock?
    end

    def outstanding
      @purchase_order.equipment_items.active.where(stock_received_on: nil).order(:id)
    end

    def prepare_form
      @batches = @purchase_order.equipment_items.includes(:product, acquisition_bid_group_line: :bid_group).order(:id).group_by(&:stock_receipt_batch)
      @attempted = @rows.index_by { |row| row['batch'] }
    end
  end
end
