# frozen_string_literal: true

module Equipment
  class Ordering
    def initialize(actor:)
      @actor = actor
      Mutation.authorize!(actor)
    end

    def call(bid_group:, expected_version:, line_versions:, application_versions:, purchase_order_attributes: {}, existing: nil, line_unit_costs: {}) # rubocop:disable Metrics/ParameterLists -- Reviewed bid, PO identity, and quoted prices.
      unit_costs = parse_unit_costs(line_unit_costs)
      order = nil
      ApplicationRecord.transaction do
        application_ids = bid_group.active_lines.left_joins(:equipment_need, :equipment_item)
                                   .distinct.pluck(Arel.sql('COALESCE(equipment_needs.application_id, equipment_items.application_id)')).compact
        applications = Mutation.lock_applications!(application_ids)
        Mutation.profile_versions!(applications, application_versions)
        needs = EquipmentNeed.where(id: bid_group.active_lines.pluck(:equipment_need_id).compact).order(:id).lock.index_by(&:id)
        bid_group.lock!
        Mutation.version!(bid_group, expected_version)
        raise Conflict, 'This bid is no longer awaiting award.' unless bid_group.open?

        applications.each { |application| Mutation.eligible_for_funding!(application, source: bid_group.funding_source) }

        lines = bid_group.active_lines.order(:id).lock.to_a
        validate_reviewed_lines!(lines, line_versions, unit_costs)

        order = obtain_order!(bid_group, existing, purchase_order_attributes)
        new_order = order.previously_new_record?
        previous_bid_ids = order.bid_groups.order(:id).ids
        previous_item_ids = order.equipment_items.ids
        items = EquipmentItem.where(id: lines.filter_map(&:equipment_item_id)).order(:id).lock.index_by(&:id)
        bid_group.update!(purchase_order: order)
        lines.each { |line| award_line!(line, bid_group, order, needs, items, unit_costs[line.id.to_s]) }
        order.update!(updated_at: Time.current) # Membership participates in the reviewed PO version.
        awarded_lines = lines.map do |line|
          line.attributes.slice(*Bidding::AUDIT_LINE_FIELDS).merge('unit_cost' => unit_costs[line.id.to_s])
        end
        changes = { bid_group_ids: [previous_bid_ids, order.bid_groups.order(:id).ids], bid_lines: [[], awarded_lines] }
        changes.merge!(order.attributes.slice('number', 'vendor_name', 'purpose', 'funding_source').transform_values { |value| [nil, value] }) if new_order
        Mutation.audit!(order, actor: @actor, action: 'equipment_order_recorded', changes: changes,
                               application_ids: application_ids, equipment_item_ids: order.equipment_items.ids - previous_item_ids,
                               purchase_order_ids: [order.id], bid_group_ids: [bid_group.id])
      end
      order
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::StaleObjectError
      raise Conflict, 'The bid or PO changed. Refresh and explicitly review the existing order.'
    rescue Icanconnect::Funding::Ineligible => e
      raise Conflict, e.message
    end

    def mark_sent!(order:, sent_at:, expected_version:)
      order.transaction do
        Mutation.lock_applications!(order.equipment_items.pluck(:application_id).compact.uniq)
        order.lock!
        Mutation.version!(order, expected_version)
        raise Conflict, 'This PO is already sent; use a reviewed correction.' if order.sent_at

        order.update!(sent_at: sent_at)
        raise Conflict, 'Enter the actual PO sent date.' unless order.sent_at

        Mutation.audit!(order, actor: @actor, action: 'equipment_po_sent', changes: order.previous_changes.slice('sent_at'),
                               purchase_order_ids: [order.id], equipment_item_ids: order.equipment_items.ids,
                               application_ids: order.equipment_items.distinct.pluck(:application_id).compact)
      end
      order
    end

    private

    def validate_reviewed_lines!(lines, versions, unit_costs)
      current = lines.to_h { |line| [line.id.to_s, line.lock_version.to_s] }
      raise Conflict, 'Review the current bid contents before award.' if lines.empty? || versions.to_h.stringify_keys.transform_values(&:to_s) != current
      raise Conflict, 'Review prices for the current bid contents before award.' if (unit_costs.keys - current.keys).any?
    end

    def parse_unit_costs(values)
      values.to_h.stringify_keys.transform_values { |value| PurchaseCosts.parse_unit_cost!(value) }
    end

    def award_line!(line, group, order, needs, items, unit_cost)
      raise Conflict, 'A selected exact model is no longer available.' unless line.product.available?

      if !group.program_stock? && !line.product.eligible_for?(line.application.program_disability_groups)
        raise Conflict, 'Catalog eligibility changed. Review this reserved equipment before award.'
      end

      if group.program_stock?
        line.quantity.times do
          EquipmentItem.create!(product: line.product, purchase_order: order, acquisition_bid_group_line: line,
                                fulfillment_source: 'program_stock_po', funding_source: order.funding_source, unit_cost: unit_cost, po_assigned_at: Time.current)
        end
      elsif line.equipment_need_id
        need = needs.fetch(line.equipment_need_id)
        raise Conflict, 'The reserved quantity or setup changed.' if need.remaining_quantity < line.quantity

        snapshot = onward_snapshot!(need.application, need.disability_setup_group)
        need.update!(remaining_quantity: need.remaining_quantity - line.quantity)
        line.quantity.times do
          EquipmentItem.create!(snapshot.merge(application: need.application, product: need.product, source_evaluation: need.source_evaluation,
                                               purchase_order: order, funding_source: order.funding_source, unit_cost: unit_cost, po_assigned_at: Time.current))
        end
      else
        item = items.fetch(line.equipment_item_id)
        raise Conflict, 'A reserved device is no longer detached.' unless item.queue_status == 'needs_ordering'

        snapshot = onward_snapshot!(item.application, item.disability_setup_group, destination: item)
        item.update!(snapshot.merge(purchase_order: order, funding_source: order.funding_source, unit_cost: unit_cost, po_assigned_at: Time.current))
        changes = item.saved_changes.slice('unit_cost', 'po_assigned_at')
        if changes.any?
          Mutation.audit!(item, actor: @actor, action: 'equipment_item_reordered', changes: changes,
                                application_ids: [item.application_id], equipment_item_ids: [item.id], purchase_order_ids: [order.id])
        end
      end
    end

    def onward_snapshot!(application, setup, destination: application)
      unless destination.shipping_ready? && application.program_disability_groups.include?(setup)
        raise Conflict,
              'Confirm the shipping destination and device setup in Review equipment.'
      end

      destination.shipping_snapshot.merge(disability_setup_group: setup)
    end

    def obtain_order!(group, existing, attributes)
      id, version = existing.to_s.split(':', 2)
      if id.present?
        order = PurchaseOrder.lock.find(id)
        Mutation.version!(order, version)
        unless order.sent_at.nil? && order.purpose == group.purpose && order.funding_source == group.funding_source
          raise Conflict,
                'Choose an unsent PO with the same purpose and funding.'
        end
      else
        order = PurchaseOrder.create!(attributes.to_h.symbolize_keys.slice(:number, :vendor_name, *EquipmentShipping::FIELDS.map(&:to_sym))
                                               .merge(purpose: group.purpose, funding_source: group.funding_source))
      end
      raise Conflict, 'Confirm the complete program receiving address.' if group.program_stock? && !order.shipping_ready?

      order
    end
  end
end
