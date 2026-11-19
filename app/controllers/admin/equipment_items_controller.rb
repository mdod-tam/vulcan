# frozen_string_literal: true

module Admin
  class EquipmentItemsController < BaseController
    include EquipmentFormHandling

    before_action :load_item

    def edit
      load_form
    end

    def update
      if params[:review] == '1'
        preview_equipment_correction(@item, attributes: item_params, fields: Equipment::Correction::ITEM_FIELDS)
        load_form
        return render_equipment_correction_review
      end

      Equipment::Correction.new(actor: current_user).update_item!(
        item: @item, attributes: item_params, expected_version: params[:expected_version], reason: params[:reason],
        operation: params[:operation].presence || 'update', confirmed_impact: params[:confirmed_impact] == '1',
        serial_duplicate_reason: params[:serial_duplicate_reason], impact_token: params[:impact_token]
      )
      redirect_to success_path, notice: 'Equipment item updated.', status: :see_other
    rescue Equipment::Conflict, ActiveRecord::RecordInvalid => e
      @form_errors = equipment_form_errors(e)
      restore_equipment_correction(@item, attributes: item_params, fields: Equipment::Correction::ITEM_FIELDS, exception: e) do |item|
        item.serial_duplicate_reason = params[:serial_duplicate_reason]
      end
      load_form
      render :edit, formats: [:html], status: :unprocessable_content
    end

    private

    def load_item
      @item = EquipmentItem.includes(:application, :product, :purchase_order).find(params.expect(:id))
      @recorded_product = @item.product
      @return_context = Equipment::RequestParameters.return_context(params)
    end

    def load_form
      @expected_version = action_name == 'edit' ? @item.lock_version : params[:expected_version]
      @products = Product.available.ordered_by_name.to_a
      [@item.product, @recorded_product].compact.each { |product| @products.unshift(product) if @products.exclude?(product) }
      @purchase_orders = [@item.purchase_order].compact
      @swap_candidates = if @item.stock? && @item.application_id?
                           EquipmentItem.available_stock.where(product_id: @item.product_id).order(:stock_received_on, :id)
                         else
                           EquipmentItem.none
                         end
      @history = @item.equipment_history
      @equipment_audit_records = Equipment::AuditRecords.for(@history.to_a)
      @previous_values = equipment_snapshot(@item, Equipment::Correction::ITEM_FIELDS) if @previous_values.nil?
    end

    def equipment_impact_extra
      { operation: params[:operation].presence || 'update' }
    end

    def item_params
      params.expect(equipment_item: Equipment::Correction::EDITABLE_ITEM_FIELDS.map(&:to_sym))
    end

    def success_path
      return admin_equipment_index_path(@return_context) if @return_context.any?

      return admin_application_path(@item.application, anchor: "equipment-item-#{@item.id}") if @item.application
      return admin_purchase_order_path(@item.purchase_order) if @item.purchase_order

      admin_stock_index_path
    end
  end
end
