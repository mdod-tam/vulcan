# frozen_string_literal: true

module Admin
  class EquipmentItemsController < BaseController
    include EquipmentFormHandling

    before_action :load_item

    def edit
      load_form
    end

    def update
      @disposition_submission = !params.key?(:equipment_item) && params.key?(:operation) && params.expect(:operation).in?(%w[detach withdraw])
      @draft_attributes = item_params.to_h
      return render_correction_step if !@disposition_submission && (params[:review] == '1' || params[:back_to_edit] == '1')

      Equipment::Correction.new(actor: current_user).update_item!(
        item: @item, attributes: @draft_attributes, expected_version: params[:expected_version], reason: params[:reason],
        operation: params[:operation].presence || 'update', confirmed_impact: params[:confirmed_impact] == '1',
        impact_token: params[:impact_token], notify_tracking: params[:notify_tracking] == '1'
      )
      redirect_to success_path, notice: 'Equipment item updated.', status: :see_other
    rescue Equipment::Conflict, ActiveRecord::RecordInvalid => e
      @form_errors = equipment_form_errors(e)
      restore_equipment_correction(@item, attributes: @draft_attributes, fields: Equipment::Correction::ITEM_FIELDS, exception: e)
      @reviewing = false
      load_form
      render :edit, formats: [:html], status: :unprocessable_content
    end

    private

    def render_correction_step
      Equipment::Mutation.version!(@item, params[:expected_version])
      if params[:back_to_edit] == '1'
        @back_to_edit = true
        @item.assign_attributes(@draft_attributes)
      else
        preview_equipment_correction(@item, attributes: @draft_attributes, fields: Equipment::Correction::ITEM_FIELDS)
      end
      load_form
      render_equipment_correction_review
    end

    def load_item
      @item = EquipmentItem.includes(:application, :product, :purchase_order).find(params.expect(:id))
      @recorded_product = @item.product
      @return_context = Equipment::RequestParameters.return_context(params)
    end

    def load_form
      @expected_version = action_name == 'edit' ? @item.lock_version : params[:expected_version]
      @stale_edit = @expected_version.to_s != @item.lock_version.to_s
      @products = Product.available.ordered_by_name.to_a
      [@item.product, @recorded_product].compact.each { |product| @products.unshift(product) if @products.exclude?(product) }
      @purchase_orders = [@item.purchase_order].compact
      return if @reviewing

      @swap_candidates = if @item.stock? && @item.application_id?
                           EquipmentItem.available_stock.where(product_id: @item.product_id).order(:stock_received_on, :id)
                         else
                           EquipmentItem.none
                         end
      @history = @item.equipment_history
      @equipment_audit_records = Equipment::AuditRecords.for(@history.to_a)
    end

    def equipment_impact_extra
      { operation: params[:operation].presence || 'update' }
    end

    def item_params
      return {} if @disposition_submission

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
