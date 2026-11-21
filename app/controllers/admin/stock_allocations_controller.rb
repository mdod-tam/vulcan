# frozen_string_literal: true

module Admin
  class StockAllocationsController < BaseController
    include EquipmentFormHandling

    def new
      @return_context = Equipment::RequestParameters.return_context(params)
      selection = Equipment::Queue.new.selection(**params.permit(need_ids: [], item_ids: []).to_h.symbolize_keys)
      @needs = selection[:needs]
      @items = selection[:items]
      raise Equipment::Conflict, 'Select requests to reserve for dispatch.' if @needs.empty? && @items.empty?

      @quantities = params.permit(quantities: {})[:quantities].to_h
      @application_versions = Equipment::Mutation.profile_versions((@needs + @items).map(&:application).uniq(&:id))
    rescue Equipment::Conflict => e
      redirect_to admin_equipment_index_path(@return_context), alert: e.message, status: :see_other
    end

    def create
      @return_context = Equipment::RequestParameters.return_context(params)
      data = params.expect(allocation: [:confirm_discontinued, :confirm_mat_funding, { needs: [%i[id quantity lock_version]], items: [%i[id lock_version]] }])
      @need_rows = data[:needs].to_a.map(&:to_h)
      @item_rows = data[:items].to_a.map(&:to_h)
      @application_versions = Equipment::RequestParameters.record_versions(params[:application_versions])
      if params[:refresh_profiles] == '1'
        load_submitted_selection
        @application_versions = Equipment::Mutation.profile_versions((@needs + @items).map(&:application).uniq(&:id))
        render_equipment_profile_review
        return
      end

      Equipment::StockAllocation.new(actor: current_user).allocate!(needs: @need_rows, items: @item_rows,
                                                                    application_versions: @application_versions, confirm_discontinued: data[:confirm_discontinued] == '1',
                                                                    confirm_mat_funding: data[:confirm_mat_funding] == '1')
      redirect_to admin_equipment_index_path(@return_context.merge(tab: 'ordered', source: 'stock')), notice: 'Stock reserved for dispatch.', status: :see_other
    rescue Equipment::Conflict, ActiveRecord::RecordInvalid => e
      @form_errors = equipment_form_errors(e)
      load_submitted_selection
      render :new, status: :unprocessable_content
    end

    def update
      @return_context = Equipment::RequestParameters.return_context(params)
      item = EquipmentItem.find(params.expect(:id))
      service = Equipment::StockAllocation.new(actor: current_user)
      if params[:replacement_id].present?
        replacement_id, replacement_version = params[:replacement_id].to_s.split(':', 2)
        service.swap!(item: item, replacement_id: replacement_id, expected_version: params[:expected_version], replacement_version: replacement_version,
                      reason: params[:reason])
      else
        service.release!(item: item, expected_version: params[:expected_version], reason: params[:reason], restore: params[:restore] == '1')
      end
      redirect_to(@return_context.any? ? admin_equipment_index_path(@return_context) : admin_stock_index_path,
                  notice: 'Stock reservation updated.', status: :see_other)
    rescue Equipment::Conflict, ActiveRecord::RecordInvalid => e
      redirect_to edit_admin_equipment_item_path(item, return_context: @return_context), alert: e.message, status: :see_other
    end

    private

    def load_submitted_selection
      @needs = EquipmentNeed.includes(:product, application: :user).where(id: @need_rows.pluck('id')).order(:id).to_a
      @items = EquipmentItem.includes(:product, application: :user).where(id: @item_rows.pluck('id')).order(:id).to_a
      @quantities = @need_rows.to_h { |row| [row['id'], row['quantity']] }
    end
  end
end
