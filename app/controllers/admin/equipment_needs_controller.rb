# frozen_string_literal: true

module Admin
  class EquipmentNeedsController < BaseController
    include EquipmentFormHandling

    before_action :set_application

    def edit
      @rows = @application.equipment_needs.order(:id).map do |need|
        need.attributes.slice('id', 'product_id', 'remaining_quantity', 'lock_version')
      end
      @expected_initialized_at = @application.equipment_needs_initialized_at&.iso8601(6).to_s
      prepare_form
    end

    def update
      submitted = params.expect(equipment_needs: [:expected_initialized_at, :reason, { rows: [%i[id product_id remaining_quantity lock_version]] }])
      @rows = Array(submitted[:rows]).map(&:to_h)
      @expected_initialized_at = submitted[:expected_initialized_at]
      @reason = submitted[:reason]
      EquipmentNeeds::Writer.update!(@application, rows: @rows, expected_initialized_at: @expected_initialized_at,
                                                   actor: current_user, reason: @reason)
      context = Equipment::RequestParameters.return_context(params[:return_context])
      redirect_to context.present? ? admin_equipment_index_path(context) : admin_application_path(@application, anchor: 'equipment'),
                  notice: 'Purchasing needs updated.'
    rescue Equipment::Conflict, ActiveRecord::RecordInvalid => e
      @form_errors = equipment_form_errors(e)
      prepare_form
      render :edit, status: :unprocessable_content
    end

    private

    def set_application
      @application = Application.find(params.expect(:application_id))
    end

    def prepare_form
      @return_context = Equipment::RequestParameters.return_context(params[:return_context])
      @products = Product.where(id: @rows.filter_map { |row| row['product_id'].presence }).index_by { |product| product.id.to_s }
      @rows << { 'id' => '', 'product_id' => '', 'remaining_quantity' => 1, 'lock_version' => '' } unless @rows.any? { |row| row['id'].blank? }
      existing_product_ids = @rows.filter_map { |row| row['product_id'] if row['id'].present? }
      selected_new_ids = @rows.filter_map { |row| row['product_id'].presence if row['id'].blank? }
      @new_products = Product.active.where.not(id: existing_product_ids).or(Product.where(id: selected_new_ids)).ordered_by_name
    end
  end
end
