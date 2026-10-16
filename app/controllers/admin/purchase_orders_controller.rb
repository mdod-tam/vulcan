# frozen_string_literal: true

module Admin
  class PurchaseOrdersController < BaseController
    include EquipmentFormHandling

    def index
      @return_context = Equipment::RequestParameters.return_context(params)
      @purchase_orders = PurchaseOrder.includes(:vendor, equipment_items: :application).recent_first
    end

    def show
      @purchase_order = PurchaseOrder.includes(:vendor, equipment_items: [:application, :product, { events: :user }]).find(params.expect(:id))
      @return_context = Equipment::RequestParameters.return_context(params)
      @history = @purchase_order.equipment_history
      @equipment_audit_records = Equipment::AuditRecords.for(@history.to_a + @purchase_order.equipment_items.flat_map { |item| item.events.to_a })
    end

    def new
      @return_context = Equipment::RequestParameters.return_context(params)
      selection = Equipment::Queue.new(**@return_context.reverse_merge(tab: 'needs_ordering').symbolize_keys)
                                  .selection(**params.permit(need_ids: [], item_ids: [], group_product_ids: []).to_h.symbolize_keys)
      raise Equipment::Conflict, 'Select equipment in Needs Ordering first.' if selection.values.all?(&:empty?)

      @need_rows = selection[:needs].map { |need| { id: need.id, quantity: need.remaining_quantity, lock_version: need.lock_version } }
      @item_rows = selection[:items].map { |item| { id: item.id, lock_version: item.lock_version } }
      @purchase_order = PurchaseOrder.new(sent_at: Date.current)
      load_review
    rescue Equipment::Conflict => e
      redirect_to admin_equipment_index_path(@return_context), alert: e.message
    end

    def create
      @return_context = Equipment::RequestParameters.return_context(params)
      permitted = params.expect(purchase_order: [:vendor_id, :number, :sent_at, :existing, :legacy_mapping,
                                                 { needs: [%i[id quantity lock_version]], items: [%i[id lock_version]] }])
      @need_rows = Array(permitted[:needs]).map { |row| row.to_h.symbolize_keys }
      @item_rows = Array(permitted[:items]).map { |row| row.to_h.symbolize_keys }
      @existing = permitted[:existing]
      @legacy_mapping = permitted[:legacy_mapping]
      @purchase_order = PurchaseOrder.new(permitted.slice(:vendor_id, :number, :sent_at))
      id, version = @existing.to_s.split(':', 2)
      order = Equipment::Ordering.new(actor: current_user).call(
        needs: @need_rows, items: @item_rows,
        purchase_order_attributes: permitted.slice(:vendor_id, :number, :sent_at).to_h,
        purchase_order_id: id.presence, expected_po_version: version,
        legacy_mapping: ActiveModel::Type::Boolean.new.cast(@legacy_mapping)
      )
      redirect_to admin_purchase_order_path(order, return_context: @return_context), notice: 'Purchase order recorded.'
    rescue Equipment::Conflict, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound => e
      @form_errors = equipment_form_errors(e)
      load_review
      render :new, status: :unprocessable_content
    end

    private

    def load_review
      @purchase_order.valid? if @form_errors.present? && @existing.blank?
      @needs = EquipmentNeed.includes(:product, :application).where(id: @need_rows.pluck(:id)).index_by(&:id)
      @items = EquipmentItem.includes(:product, :application).where(id: @item_rows.pluck(:id)).index_by(&:id)
      @vendors = Users::Vendor.equipment_procurement_eligible.order(:business_name)
      @existing_orders = PurchaseOrder.includes(:vendor).recent_first
      @existing_options = @existing_orders.map do |order|
        ["#{order.vendor.business_name} · #{order.number} · #{helpers.accessible_date_value(order.sent_at)}", "#{order.id}:#{order.lock_version}"]
      end
      if @existing.present? && @existing_options.none? { |_label, value| value == @existing }
        @existing_options << ['Previous PO selection changed; return to Equipment and refresh', @existing]
      end
      @application_count = (@needs.values + @items.values).map(&:application_id).uniq.size
      @unit_count = @need_rows.sum { |row| row[:quantity].to_i } + @item_rows.size
    end
  end
end
