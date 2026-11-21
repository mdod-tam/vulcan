# frozen_string_literal: true

module Admin
  class EquipmentShipmentsController < BaseController
    include EquipmentFormHandling

    def new
      @return_context = Equipment::RequestParameters.return_context(params)
      @items = EquipmentItem.ordered.includes(:product, :acquisition_bid_group_line, application: :user).where(id: params[:item_ids]).order(:id)
      ids = Array(params[:item_ids]).map(&:to_s)
      raise Equipment::Conflict, 'The selected shipment units changed. Review the whole group.' if ids.empty? || ids.sort != @items.map { |item| item.id.to_s }.sort

      @rows = @items.to_h { |item| [item.id.to_s, item.attributes.slice('id', 'lock_version', 'serial_number', 'imei')] }
    rescue Equipment::Conflict => e
      redirect_to_queue(e.message)
    end

    def create
      @return_context = Equipment::RequestParameters.return_context(params)
      data = params.expect(shipment: [:shipped_at, :tracking_number, :carrier, :confirm_setup, { rows: [%i[id lock_version serial_number imei]] }])
      rows = data[:rows].to_a.map(&:to_h)
      Equipment::Shipment.new(actor: current_user).call(rows: rows, attributes: data.to_h, confirm_setup: data[:confirm_setup] == '1')
      redirect_to admin_equipment_index_path(@return_context.merge(tab: 'shipped')), notice: 'Outbound shipment recorded.', status: :see_other
    rescue Equipment::Shipment::SelectionChanged => e
      redirect_to_queue(e.message)
    rescue Equipment::Conflict, ActiveRecord::RecordInvalid => e
      @form_errors = equipment_form_errors(e)
      @items = EquipmentItem.ordered.includes(:product, :acquisition_bid_group_line, application: :user).where(id: rows.pluck('id')).order(:id).to_a
      @rows = rows.index_by { |row| row['id'].to_s }
      if @items.size != rows.size || @items.any? { |item| item.lock_version.to_s != @rows.fetch(item.id.to_s)['lock_version'].to_s }
        return redirect_to_queue('The selected devices changed. Select them again.')
      end

      render :new, status: :unprocessable_content
    end

    private

    def redirect_to_queue(message)
      redirect_to admin_equipment_index_path(@return_context.merge(tab: 'ordered')), alert: message, status: :see_other
    end
  end
end
