# frozen_string_literal: true

module Admin
  class EquipmentController < BaseController
    def index
      @context = Equipment::RequestParameters.return_context(params).reverse_merge(tab: 'needs_ordering')
      queue = Equipment::Queue.new(**@context.symbolize_keys)
      @groups = queue.groups
      @delivery_retry = flash[:delivery_retry]&.with_indifferent_access
      flash.delete(:delivery_retry)
      @dispatch_groups = queue.dispatch_groups if @context[:tab] == 'ordered'
      @products = Product.ordered_by_name
      @available_counts = equipment_navigation_summary.available_counts
    end
  end
end
