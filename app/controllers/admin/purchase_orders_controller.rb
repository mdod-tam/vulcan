# frozen_string_literal: true

module Admin
  class PurchaseOrdersController < BaseController
    include EquipmentFormHandling

    def index
      @return_context = Equipment::RequestParameters.return_context(params)
      @purchase_orders = PurchaseOrder.includes(:bid_groups, equipment_items: :application).recent_first
      if params[:application_id].present?
        @purchase_orders = @purchase_orders.where(id: EquipmentItem.where(application_id: params[:application_id]).select(:purchase_order_id))
      end
      @purchase_orders = @purchase_orders.ready_to_send if params[:state] == 'unsent'
      @purchase_orders = @purchase_orders.where(purpose: 'program_stock') if params[:purpose] == 'program_stock'
    end

    def show
      @purchase_order = PurchaseOrder.includes(:bid_groups,
                                               equipment_items: [:application, :product, :acquisition_bid_group_line, { events: :user }]).find(params.expect(:id))
      @return_context = Equipment::RequestParameters.return_context(params)
      @history = @purchase_order.equipment_history
      @equipment_audit_records = Equipment::AuditRecords.for(@history.to_a + @purchase_order.equipment_items.flat_map { |item| item.events.to_a })
    end

    def new
      @return_context = Equipment::RequestParameters.return_context(params)
      @group = BidGroup.find(params.expect(:bid_group_id))
      @purchase_order = PurchaseOrder.new(purpose: @group.purpose)
      @line_unit_costs = {}
      @expected_version = @group.lock_version
      @line_versions = @group.active_lines.to_h { |line| [line.id.to_s, line.lock_version] }
      load_review
      @application_versions = Equipment::Mutation.profile_versions(@lines.filter_map(&:application).uniq(&:id))
    end

    def create
      @return_context = Equipment::RequestParameters.return_context(params)
      @group = BidGroup.find_by(id: params.expect(:bid_group_id))
      return head(:not_found) unless @group

      data = params.expect(purchase_order: [:number, :vendor_name, :existing, *EquipmentShipping::FIELDS])
      @purchase_order = PurchaseOrder.new(data.except(:existing).to_h.merge(purpose: @group.purpose))
      @line_unit_costs = params.permit(line_unit_costs: {}).fetch(:line_unit_costs, {}).to_h
      @existing = data[:existing]
      @expected_version = params[:expected_version]
      @line_versions = Equipment::RequestParameters.record_versions(params[:line_versions])
      @application_versions = Equipment::RequestParameters.record_versions(params[:application_versions])
      if params[:refresh_profiles] == '1'
        load_review
        @application_versions = Equipment::Mutation.profile_versions(@lines.filter_map(&:application).uniq(&:id))
        render_equipment_profile_review
        return
      end

      order = Equipment::Ordering.new(actor: current_user).call(
        bid_group: @group, expected_version: @expected_version, line_versions: @line_versions,
        application_versions: @application_versions, purchase_order_attributes: data.except(:existing).to_h, existing: @existing,
        line_unit_costs: @line_unit_costs
      )
      redirect_to admin_purchase_order_path(order, return_context: @return_context), notice: 'Award and unsent PO recorded.', status: :see_other
    rescue Equipment::Conflict, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound => e
      @form_errors = equipment_form_errors(e)
      load_review
      render :new, status: :unprocessable_content
    end

    def send_order
      order = PurchaseOrder.find(params.expect(:id))
      Equipment::Ordering.new(actor: current_user).mark_sent!(order: order, sent_at: params[:sent_at], expected_version: params[:expected_version])
      redirect_to admin_purchase_order_path(order), notice: 'PO marked sent.', status: :see_other
    rescue Equipment::Conflict, ActiveRecord::RecordInvalid => e
      redirect_to admin_purchase_order_path(order), alert: e.message, status: :see_other
    end

    private

    def load_review
      @lines = @group.active_lines.includes(:product).order(:id).to_a
      need_lines = @lines.select(&:equipment_need_id?)
      item_lines = @lines.select(&:equipment_item_id?)
      ActiveRecord::Associations::Preloader.new(records: need_lines, associations: { equipment_need: { application: :user } }).call if need_lines.any?
      ActiveRecord::Associations::Preloader.new(records: item_lines, associations: { equipment_item: { application: :user } }).call if item_lines.any?
      @vendor_names = PurchaseOrder.where.not(vendor_name: [nil, '']).distinct.order(:vendor_name).pluck(:vendor_name)
      @existing_orders = PurchaseOrder.unsent.where(purpose: @group.purpose, funding_source: @group.funding_source)
                                      .includes(equipment_items: [:product, { application: :user }]).recent_first.to_a
      @existing_options = @existing_orders.map { |order| [order.selection_label, "#{order.id}:#{order.lock_version}"] }
      return unless @existing.present? && @existing_options.none? { |_label, value| value == @existing }

      @existing_options << ['Previous PO selection changed — review the current order before choosing again', @existing]
    end
  end
end
