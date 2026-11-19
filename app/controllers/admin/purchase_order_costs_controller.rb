# frozen_string_literal: true

module Admin
  class PurchaseOrderCostsController < BaseController
    def update
      order = PurchaseOrder.find(params.expect(:purchase_order_id))
      data = params.expect(costs: [:expected_version, *Equipment::PurchaseCosts::ORDER_FIELDS, { rows: [%i[id lock_version unit_cost]] }])
      Equipment::PurchaseCosts.update!(order: order, rows: data[:rows], expected_version: data[:expected_version], actor: current_user,
                                       order_attributes: data.slice(*Equipment::PurchaseCosts::ORDER_FIELDS))
      redirect_to admin_purchase_order_path(order), notice: 'Actual device purchase costs saved.', status: :see_other
    rescue Equipment::Conflict, ActiveRecord::RecordInvalid => e
      @purchase_order = order.reload
      @purchase_order.assign_attributes(data.slice(*Equipment::PurchaseCosts::ORDER_FIELDS))
      @form_errors = [e.message]
      @cost_rows = data[:rows].to_a.map(&:to_h).index_by { |row| row['id'].to_s }
      render :edit, status: :unprocessable_content
    end
  end
end
