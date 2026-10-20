# frozen_string_literal: true

module Admin
  class PurchaseOrderCorrectionsController < BaseController
    include EquipmentFormHandling

    before_action :load_order

    def edit; end

    def update
      if params[:review] == '1'
        preview_equipment_correction(@purchase_order, attributes: order_params, fields: Equipment::Correction::PO_FIELDS)
        return render_equipment_correction_review
      end

      Equipment::Correction.new(actor: current_user).update_purchase_order!(
        purchase_order: @purchase_order, attributes: order_params, expected_version: params[:expected_version],
        expected_item_versions: @submitted_versions, reason: params[:reason],
        confirmed_impact: params[:confirmed_impact] == '1', impact_token: params[:impact_token]
      )
      redirect_to admin_purchase_order_path(@purchase_order, return_context: @return_context), notice: 'Purchase order corrected.', status: :see_other
    rescue Equipment::Conflict, ActiveRecord::RecordInvalid => e
      @form_errors = equipment_form_errors(e)
      restore_equipment_correction(@purchase_order, attributes: order_params, fields: Equipment::Correction::PO_FIELDS, exception: e)
      @items = @purchase_order.equipment_items.includes(:product, :application).order(:id).to_a
      render :edit, formats: [:html], status: :unprocessable_content
    end

    private

    def load_order
      @purchase_order = PurchaseOrder.find(params.expect(:purchase_order_id))
      @return_context = Equipment::RequestParameters.return_context(params)
      @submitted_versions = Equipment::RequestParameters.record_versions(params[:item_versions])
      @items = @purchase_order.equipment_items.includes(:product, :application).order(:id).to_a
      @vendors = Users::Vendor.equipment_procurement_eligible.order(:business_name, :id).to_a
      @vendors.unshift(@purchase_order.vendor) if @vendors.exclude?(@purchase_order.vendor)
      @previous_values = equipment_snapshot(@purchase_order, Equipment::Correction::PO_FIELDS)
      @expected_version = action_name == 'edit' ? @purchase_order.lock_version : params[:expected_version]
      @item_versions = action_name == 'edit' ? @items.to_h { |item| [item.id.to_s, item.lock_version.to_s] } : @submitted_versions
    end

    def equipment_impact_extra
      { item_versions: @submitted_versions }
    end

    def order_params
      params.expect(purchase_order: %i[vendor_id number sent_at])
    end
  end
end
