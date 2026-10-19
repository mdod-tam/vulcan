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
        purchase_order_versions: @submitted_versions,
        new_purchase_order: (new_order_params if params[:create_purchase_order] == '1'),
        serial_duplicate_reason: params[:serial_duplicate_reason], impact_token: params[:impact_token]
      )
      redirect_to success_path, notice: 'Equipment item updated.', status: :see_other
    rescue Equipment::Conflict, ActiveRecord::RecordInvalid => e
      @form_errors = equipment_form_errors(e)
      restore_equipment_correction(@item, attributes: item_params, fields: Equipment::Correction::ITEM_FIELDS) do |item|
        item.serial_duplicate_reason = params[:serial_duplicate_reason]
      end
      load_form
      render :edit, formats: [:html], status: :unprocessable_content
    end

    private

    def load_item
      @item = EquipmentItem.includes(:application, :product, purchase_order: :vendor).find(params.expect(:id))
      @recorded_product = @item.product
      @return_context = Equipment::RequestParameters.return_context(params)
      @submitted_versions = Equipment::RequestParameters.record_versions(params[:purchase_order_versions])
    end

    def load_form
      @expected_version = action_name == 'edit' ? @item.lock_version : params[:expected_version]
      @products = Product.active.ordered_by_name.to_a
      [@item.product, @recorded_product].compact.each { |product| @products.unshift(product) if @products.exclude?(product) }
      @purchase_orders = PurchaseOrder.includes(:vendor).recent_first.to_a
      @purchase_order_versions = action_name == 'edit' ? @purchase_orders.to_h { |order| [order.id.to_s, order.lock_version.to_s] } : @submitted_versions
      @vendors = Users::Vendor.equipment_procurement_eligible.order(:business_name, :id)
      @new_purchase_order = PurchaseOrder.new(params[:new_purchase_order].present? ? new_order_params : {})
      @new_purchase_order.valid? if @form_errors.present? && params[:create_purchase_order] == '1'
      @history = @item.events.includes(:user).order(created_at: :desc, id: :desc)
      @equipment_audit_records = Equipment::AuditRecords.for(@history.to_a)
      @previous_values = equipment_snapshot(@item, Equipment::Correction::ITEM_FIELDS) if @previous_values.nil?
    end

    def equipment_impact_extra
      { operation: params[:operation].presence || 'update', new_purchase_order: (params[:create_purchase_order] == '1' ? new_order_params : {}) }
    end

    def item_params
      params.expect(equipment_item: %i[product_id purchase_order_id shipped_at tracking_number carrier serial_number imei])
    end

    def new_order_params
      params.expect(new_purchase_order: %i[vendor_id number sent_at])
    end

    def success_path
      return admin_equipment_index_path(@return_context) if @return_context.any?

      admin_application_path(@item.application, anchor: "equipment-item-#{@item.id}")
    end
  end
end
