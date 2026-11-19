# frozen_string_literal: true

module Equipment
  class Bidding
    AUDIT_LINE_FIELDS = %w[id product_id quantity equipment_need_id equipment_item_id supplier_setup_group released_at].freeze

    def initialize(actor:)
      @actor = actor
      Mutation.authorize!(actor)
    end

    def create!(number:, needs: [], items: [], stock: [], purpose: 'direct_to_constituents', funding_source: 'mat', existing: nil) # rubocop:disable Metrics/ParameterLists -- Explicit bid identity and selection fields.
      group = nil
      ApplicationRecord.transaction do
        rows = needs.map(&:symbolize_keys)
        units = items.map(&:symbolize_keys)
        validate_selection!(rows, units, stock)
        applications = lock_requests!(rows, units)
        applications.each { |application| Mutation.eligible_for_funding!(application, source: funding_source) }
        group = obtain_group!(number, purpose, funding_source, existing)
        before = audit_lines(group)
        application_ids = (applications.map(&:id) + beneficiary_ids(group)).uniq
        if group.program_stock?
          reserve_stock!(group, rows, units, stock)
        else
          raise Conflict, 'Direct bids cannot include stock lines.' if stock.any?

          reserve_needs!(group, rows)
          reserve_items!(group, units)
        end
        group.update!(membership_changed_at: Time.current) if existing.present?
        changes = { bid_lines: [before, audit_lines(group)] }
        changes.merge!(group.saved_changes.slice('number', 'purpose', 'funding_source'))
        Mutation.audit!(group, actor: @actor, action: existing.present? ? 'equipment_bid_amended' : 'equipment_bid_created', changes: changes,
                               application_ids: application_ids, bid_group_ids: [group.id])
      end
      group
    rescue ActiveRecord::RecordNotUnique
      raise Conflict, 'This bid number already exists. Open its current contents.'
    rescue Icanconnect::Funding::Ineligible => e
      raise Conflict, e.message
    end

    def release!(group:, line_ids:, expected_version:, reason:, cancel: false)
      amend!(group: group, expected_version: expected_version, reason: reason) do |lines|
        selected = cancel ? lines : lines.select { |line| Array(line_ids).map(&:to_s).include?(line.id.to_s) }
        raise Conflict, 'The selected bid lines changed.' if !cancel && (selected.empty? || selected.size != Array(line_ids).size)

        selected.each do |line|
          line.update!(released_at: Time.current)
          line.equipment_item&.update!(unfulfilled_since: Time.current)
        end
        group.cancelled_at = Time.current if cancel
      end
    end

    def change_quantities!(group:, rows:, expected_version:, reason:)
      submitted = rows.map { |row| row.to_h.with_indifferent_access }
      amend!(group: group, expected_version: expected_version, reason: reason) do |lines|
        unless submitted.map { |row| row[:id].to_s }.sort == lines.map { |line| line.id.to_s }.sort
          raise Conflict, 'Review every current bid line before changing quantities.'
        end

        lines.each do |line|
          row = submitted.find { |entry| entry[:id].to_s == line.id.to_s }
          Mutation.version!(line, row[:lock_version])
          quantity = positive!(row[:quantity])
          raise Conflict, 'A detached device remains one physical unit.' if line.equipment_item_id && quantity != 1
          if line.equipment_need && quantity > line.equipment_need.available_quantity + line.quantity
            raise Conflict, 'The requested quantity is reserved elsewhere or no longer wanted.'
          end

          line.update!(quantity: quantity)
        end
      end
    end

    private

    def audit_lines(group)
      group.bid_group_lines.order(:id).map { |line| line.attributes.slice(*AUDIT_LINE_FIELDS) }
    end

    def beneficiary_ids(group)
      group.active_lines.left_joins(:equipment_need, :equipment_item)
           .distinct.pluck(Arel.sql('COALESCE(equipment_needs.application_id, equipment_items.application_id)')).compact
    end

    def validate_selection!(needs, items, stock)
      raise Conflict, 'Select at least one request or stock quantity.' if needs.empty? && items.empty? && stock.empty?
      return if needs.pluck(:id).map(&:to_s).uniq.size == needs.size && items.pluck(:id).map(&:to_s).uniq.size == items.size

      raise Conflict, 'Select each row only once.'
    end

    def lock_requests!(rows, units)
      requests = EquipmentNeed.where(id: rows.pluck(:id)).to_a + EquipmentItem.where(id: units.pluck(:id)).to_a
      raise Conflict, 'A selected request disappeared.' unless requests.size == rows.size + units.size

      applications = Mutation.lock_applications!(requests.map(&:application_id).compact.uniq)
      EquipmentNeed.where(id: rows.pluck(:id)).order(:id).lock.load
      applications
    end

    def obtain_group!(number, purpose, funding, existing)
      id, version = existing.to_s.split(':', 2)
      return BidGroup.create!(number: number, purpose: purpose, funding_source: funding) if id.blank?

      group = BidGroup.lock.find(id)
      Mutation.version!(group, version)
      raise Conflict, 'Choose an open bid with the same purpose and funding.' unless group.open? && group.purpose == purpose && group.funding_source == funding

      group
    end

    def reserve_stock!(group, needs, items, stock)
      raise Conflict, 'Stock bids cannot include application requests.' if needs.any? || items.any?

      stock.each do |entry|
        row = entry.symbolize_keys
        product = Product.available.find(row[:product_id])
        group.bid_group_lines.create!(product: product, quantity: positive!(row[:quantity]), supplier_setup_group: row[:supplier_setup_group].presence)
      end
    end

    def reserve_needs!(group, rows)
      EquipmentNeed.where(id: rows.pluck(:id)).order(:id).each do |need|
        row = rows.find { |entry| entry[:id].to_s == need.id.to_s }
        Mutation.version!(need, row[:lock_version])
        quantity = positive!(row[:quantity])
        raise Conflict, 'Selected quantity is already reserved or exceeds the request.' if quantity > need.available_quantity

        validate_product!(need.product, need.application)
        group.bid_group_lines.create!(equipment_need: need, product: need.product, quantity: quantity)
      end
    end

    def reserve_items!(group, rows)
      EquipmentItem.where(id: rows.pluck(:id)).order(:id).lock.each do |item|
        row = rows.find { |entry| entry[:id].to_s == item.id.to_s }
        Mutation.version!(item, row[:lock_version])
        raise Conflict, 'This detached unit is unavailable or already reserved.' unless item.queue_status == 'needs_ordering' && !item.bid_group_lines.reserved.exists?

        validate_product!(item.product, item.application)
        group.bid_group_lines.create!(equipment_item: item, product: item.product, quantity: 1)
      end
    end

    def validate_product!(product, application)
      return if product.available? && product.eligible_for?(application.program_disability_groups)

      raise Conflict, 'Review unavailable or ineligible equipment before bidding.'
    end

    def amend!(group:, expected_version:, reason:)
      raise Conflict, 'Provide an amendment reason.' if reason.to_s.strip.blank?

      group.transaction do
        application_ids = beneficiary_ids(group)
        Mutation.lock_applications!(application_ids)
        needs = EquipmentNeed.where(id: group.active_lines.pluck(:equipment_need_id).compact).order(:id).lock.to_a
        exhausted = needs.select { |need| need.available_quantity.zero? }
        group.lock!
        Mutation.version!(group, expected_version)
        raise Conflict, 'Only open bids can be amended.' unless group.open?

        lines = group.active_lines.order(:id).lock.to_a
        before = audit_lines(group)
        previous_cancelled_at = group.cancelled_at
        yield lines
        exhausted.each { |need| need.update!(unfulfilled_since: Time.current) if need.available_quantity.positive? }
        group.update!(membership_changed_at: Time.current)
        changes = { bid_lines: [before, audit_lines(group)] }
        changes[:cancelled_at] = [previous_cancelled_at, group.cancelled_at] if previous_cancelled_at != group.cancelled_at
        Mutation.audit!(group, actor: @actor, action: 'equipment_bid_amended', changes: changes, reason: reason,
                               application_ids: application_ids, bid_group_ids: [group.id])
      end
      group
    end

    def positive!(value)
      number = Integer(value.to_s, 10)
      raise Conflict, 'Enter positive whole quantities.' unless number.positive?

      number
    rescue ArgumentError
      raise Conflict, 'Enter positive whole quantities.'
    end
  end
end
