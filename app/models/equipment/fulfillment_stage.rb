# frozen_string_literal: true

module Equipment
  # Reads the earliest unfinished obligation without changing application approval.
  class FulfillmentStage
    Definition = Data.define(:key, :label, :action)
    Outstanding = Data.define(:stage, :quantity, :entered_at)
    Result = Data.define(:stage, :entered_at, :progress, :action, :secondary, :action_context)

    DEFINITIONS = [
      Definition.new(:needs_evaluator, 'Assign evaluator', 'Assign evaluator'),
      Definition.new(:awaiting_report, 'Enter evaluation report', 'Enter evaluation report'),
      Definition.new(:needs_fulfillment, 'Needs bid number', 'Enter bid number'),
      Definition.new(:awaiting_bid_award, 'Enter PO details', 'Enter PO details'),
      Definition.new(:ready_to_send_po, 'Record PO sent date', 'Record PO sent date'),
      Definition.new(:awaiting_shipment, 'Enter shipping info', 'Enter shipping info'),
      Definition.new(:shipment_recorded, 'View shipment history', 'View shipment history')
    ].freeze

    def initialize(application)
      @application = application
    end

    def result
      obligations = outstanding
      primary = obligations.first
      stage = primary&.stage || completed_stage
      Result.new(stage:, entered_at: primary&.entered_at || completed_at(stage),
                 progress: progress(stage), action: action(stage), secondary: obligations.drop(1), action_context: action_context(stage))
    end

    def needs_evaluation?
      application.equipment_needs_initialized_at.nil? && needs.empty? && items.empty?
    end

    def requests_to_fulfill
      unreserved_needs + detached_items
    end

    def equipment_selection_needed?
      application.equipment_catalog_product_pending? || requests_to_fulfill.empty?
    end

    def catalog_review_requests
      return [] if application.equipment_catalog_product_pending?

      unreserved_needs.select { |need| need.setup_ready? && application.shipping_ready? } +
        detached_items.select { |item| item.setup_ready? && item.shipping_ready? }
    end

    private

    attr_reader :application

    def items
      @items ||= application.equipment_items.reject(&:withdrawn_at?)
    end

    def needs
      @needs ||= application.equipment_needs.select { |need| need.remaining_quantity.positive? }
    end

    def reservations
      @reservations ||= (needs.flat_map(&:bid_group_lines) + items.flat_map(&:bid_group_lines)).uniq(&:id).select do |line|
        !line.released_at? && !line.bid_group.cancelled_at? && !line.bid_group.purchase_order_id?
      end
    end

    def open_evaluations
      application.open_equipment_evaluations
    end

    def outstanding
      [evaluation_work, fulfillment_work, bid_work, unsent_work, shipment_work].compact
    end

    def evaluation_work
      return unless needs_evaluation?

      stage = open_evaluations.any? ? :awaiting_report : :needs_evaluator
      entered_at = stage == :awaiting_report ? application.report_wait_started_at : application.needs_evaluator_since
      Outstanding.new(stage:, quantity: nil, entered_at:)
    end

    def unreserved_needs
      needs.select { |need| need.available_quantity.positive? }
    end

    def detached_items
      items.select { |item| item.queue_status == 'needs_ordering' && reservations.none? { |line| line.equipment_item_id == item.id } }
    end

    def fulfillment_work
      unreserved = unreserved_needs
      detached = detached_items
      quantity = unreserved.sum(&:available_quantity) + detached.size
      unresolved = application.equipment_catalog_product_pending?
      return unless quantity.positive? || unresolved

      dates = unreserved.map(&:unfulfilled_since) + detached.map(&:unfulfilled_since)
      dates << application.equipment_source_report&.report_submitted_at if unresolved
      Outstanding.new(stage: :needs_fulfillment, quantity: quantity.positive? ? quantity : nil, entered_at: oldest(dates))
    end

    def bid_work
      return if reservations.empty?

      Outstanding.new(stage: :awaiting_bid_award, quantity: reservations.sum(&:quantity), entered_at: oldest(reservations.map(&:created_at)))
    end

    def unsent_work
      unsent = unsent_items
      Outstanding.new(stage: :ready_to_send_po, quantity: unsent.size, entered_at: oldest(unsent.map(&:po_assigned_at))) if unsent.any?
    end

    def unsent_items
      items.select { |item| item.direct_vendor? && item.purchase_order && item.purchase_order.sent_at.nil? && item.shipped_at.nil? }
    end

    def shipment_work
      awaiting = items.select(&:awaiting_shipment?)
      return if awaiting.empty?

      dates = awaiting.map(&:shipment_wait_started_at)
      Outstanding.new(stage: :awaiting_shipment, quantity: awaiting.size, entered_at: oldest(dates))
    end

    def oldest(dates)
      dates.map(&:to_time).min if dates.any? && dates.none?(&:nil?)
    end

    def completed_stage
      return :shipment_recorded if items.any?(&:shipped_at?)
      return :no_equipment if application.equipment_needs_decided?

      :needs_fulfillment
    end

    def completed_at(stage)
      case stage
      when :shipment_recorded then items.filter_map(&:shipped_at).max&.to_time
      when :no_equipment then application.equipment_needs_decided_at
      when :needs_fulfillment then application.equipment_source_report&.report_submitted_at
      end
    end

    def action(stage)
      return 'Choose equipment for bid' if stage == :needs_fulfillment && equipment_selection_needed?
      return 'Prepare bid' if stage == :needs_fulfillment && requests_need_review?
      return 'View application' if stage == :no_equipment

      DEFINITIONS.find { |definition| definition.key == stage }.action
    end

    def requests_need_review?
      return true if application.equipment_catalog_product_pending?
      return true if needs.empty? && detached_items.empty?

      needs.any? { |need| need.available_quantity.positive? && (!need.setup_ready? || !application.shipping_ready? || !catalog_ready?(need.product)) } ||
        detached_items.any? { |item| !item.setup_ready? || !item.shipping_ready? || !catalog_ready?(item.product) }
    end

    def catalog_ready?(product)
      product.available? && product.eligible_for?(application.program_disability_groups)
    end

    def action_context(stage)
      case stage
      when :awaiting_bid_award then { bid_group_ids: reservations.map(&:bid_group_id).uniq }
      when :ready_to_send_po then { purchase_order_ids: unsent_items.map(&:purchase_order_id).uniq }
      when :awaiting_shipment
        sources = items.select(&:awaiting_shipment?).map(&:stock?).uniq
        return {} unless sources.size == 1

        { source: sources.first ? 'stock' : 'vendor' }
      else {}
      end
    end

    def progress(stage)
      return 'Ready for evaluator assignment' if stage == :needs_evaluator
      return 'Evaluator assigned · report not submitted' if stage == :awaiting_report
      return 'Review equipment' if stage == :needs_fulfillment && application.equipment_catalog_product_pending?
      return 'No equipment needed' if stage == :no_equipment

      total = items.size + needs.sum(&:remaining_quantity)
      return 'Review equipment' if stage == :needs_fulfillment && total.zero?

      "#{items.count(&:shipped_at?)} of #{total} #{'unit'.pluralize(total)} shipped"
    end
  end
end
