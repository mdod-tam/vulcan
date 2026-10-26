# frozen_string_literal: true

module Admin
  class EquipmentController < BaseController
    def index
      @context = Equipment::RequestParameters.return_context(params).reverse_merge(tab: 'needs_ordering')
      queue = Equipment::Queue.new(**@context.symbolize_keys)
      respond_to do |format|
        format.html do
          @groups = queue.groups
          @products = Product.ordered_by_name
          @vendors = Users::Vendor.equipment_procurement_eligible.order(:business_name)
        end
        format.csv { export(queue) }
      end
    end

    private

    def export(queue)
      raise Equipment::Conflict, 'Bid exports apply to Needs Ordering.' unless @context[:tab] == 'needs_ordering'

      selected = %i[need_ids item_ids group_product_ids].any? { |key| params[key].present? }
      rows = if selected
               selection = queue.selection(**params.permit(need_ids: [], item_ids: [], group_product_ids: []).to_h.symbolize_keys)
               selection.values.flatten
             else
               queue.groups.flat_map(&:last)
             end
      headers = ['Manufacturer', 'Catalog model', 'Model identifier', 'Required quantity']
      csv = CsvExport.generate(headers: headers, actor: current_user, export_type: 'equipment_bids') do |file|
        rows.group_by(&:product).each do |product, records|
          quantity = records.sum { |record| record.is_a?(EquipmentNeed) ? record.remaining_quantity : 1 }
          file << [product.manufacturer, product.name, product.model_number, quantity]
        end
      end
      send_data csv, type: 'text/csv; charset=utf-8', filename: "equipment-bids-#{Date.current.iso8601}.csv", disposition: 'attachment'
    rescue Equipment::Conflict => e
      redirect_to admin_equipment_index_path(@context), alert: e.message
    end
  end
end
