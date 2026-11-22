# frozen_string_literal: true

module Admin
  class EquipmentNeedsController < BaseController
    include EquipmentFormHandling

    before_action :set_application

    def edit
      @rows = @application.equipment_needs.order(:id).map do |need|
        need.attributes.slice('id', 'product_id', 'remaining_quantity', 'lock_version', 'disability_setup_group')
      end
      @expected_initialized_at = @application.equipment_needs_initialized_at&.iso8601(6).to_s
      @expected_profile_version = @application.equipment_profile_version
      prepare_form
    end

    def update
      submitted = params.expect(equipment_needs: [:expected_initialized_at, :expected_profile_version, :reason,
                                                  { profile: [*EquipmentShipping::FIELDS, { program_disability_groups: [] }],
                                                    rows: [%i[id product_id remaining_quantity lock_version disability_setup_group]] }])
      @rows = Array(submitted[:rows]).map(&:to_h)
      @expected_initialized_at = submitted[:expected_initialized_at]
      @expected_profile_version = submitted[:expected_profile_version]
      @reason = submitted[:reason]
      @profile_values = @application.shipping_snapshot.merge(submitted[:profile].to_h.slice(*EquipmentShipping::FIELDS)) if submitted[:profile]
      ApplicationRecord.transaction do
        @application.lock!
        Equipment::Mutation.profile_versions!([@application], { @application.id.to_s => @expected_profile_version })
        @application.update_equipment_profile!(submitted[:profile], actor: current_user, reason: @reason) if submitted[:profile]
        EquipmentNeeds::Writer.update!(@application, rows: @rows, expected_initialized_at: @expected_initialized_at,
                                                     actor: current_user, reason: @reason)
      end
      context = Equipment::RequestParameters.return_context(params[:return_context])
      redirect_to context.present? ? admin_equipment_index_path(context) : admin_application_path(@application, anchor: 'equipment'),
                  notice: 'Purchasing needs updated.', status: :see_other
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
      @history = @application.events.where(action: %w[equipment_needs_initialized equipment_needs_updated equipment_profile_updated])
                             .includes(:user).order(created_at: :desc, id: :desc).to_a
      @equipment_audit_records = Equipment::AuditRecords.for(@history)
      @profile_values ||= @application.suggested_shipping_snapshot
      @return_context = Equipment::RequestParameters.return_context(params[:return_context])
      @products = Product.where(id: @rows.filter_map { |row| row['product_id'].presence }).index_by { |product| product.id.to_s }
      unless @rows.any? { |row| row['id'].blank? }
        @rows << { 'id' => '', 'product_id' => '', 'remaining_quantity' => 1, 'lock_version' => '',
                   'disability_setup_group' => @application.default_equipment_setup_group }
      end
      existing_product_ids = @rows.filter_map { |row| row['product_id'] if row['id'].present? }
      selected_new_ids = @rows.filter_map { |row| row['product_id'].presence if row['id'].blank? }
      @new_products = Product.available.where.not(id: existing_product_ids).or(Product.where(id: selected_new_ids)).ordered_by_name
    end
  end
end
