# frozen_string_literal: true

module Equipment
  class StockAllocation
    def initialize(actor:)
      @actor = actor
      Mutation.authorize!(actor)
    end

    def allocate!(application_versions:, needs: [], items: [], confirm_discontinued: false, confirm_mat_funding: false)
      targets = parsed_targets(needs, items)
      validate_targets!(targets)

      allocated = []
      EquipmentItem.transaction do
        application_ids = targets.map { |type, row| type.find(row[:id]).application_id }.uniq
        applications = Mutation.lock_applications!(application_ids)
        Mutation.profile_versions!(applications, application_versions)
        applications.each { |application| Mutation.eligible_for_funding!(application, source: 'mat') }
        EquipmentNeed.where(application_id: application_ids).order(:id).lock.load
        BidGroup.where(id: BidGroupLine.reserved.where(equipment_need_id: targets.filter_map do |type, row|
          row[:id] if type == EquipmentNeed
        end).select(:bid_group_id)).order(:id).lock.load
        resolved = targets.map do |type, row|
          target = type.find(row[:id])
          review_target!(target, type == EquipmentNeed ? row[:quantity] : 1, confirm_discontinued, confirm_mat_funding, row[:lock_version])
          [type, row, target]
        end
        stock = lock_stock_selection!(resolved)
        resolved.each do |type, row, target|
          allocated.concat(allocate_target!(type, row, target, stock, confirm_discontinued, confirm_mat_funding))
        end
      end
      allocated
    end

    def release!(item:, expected_version:, reason:, restore: true)
      raise Conflict, 'Provide a release reason.' if reason.to_s.strip.blank?

      item.transaction do
        lock_allocation!(item)
        Mutation.version!(item, expected_version)
        require_reserved!(item)
        previous_application = item.application_id
        detached = EquipmentItem.find_by(replaced_by_equipment_item_id: item.id)
        if detached
          detached.lock!
          detached.update!(replaced_by_equipment_item: nil, withdrawn_at: (restore ? nil : detached.withdrawn_at),
                           unfulfilled_since: (restore ? Time.current : detached.unfulfilled_since))
          Mutation.audit!(detached, actor: @actor, action: 'equipment_replacement_released',
                                    changes: detached.saved_changes.except('updated_at', 'lock_version'), reason: reason,
                                    application_ids: [previous_application], equipment_item_ids: [detached.id, item.id])
        elsif restore && item.allocation_equipment_need
          need = item.allocation_equipment_need
          update_need_quantity!(need, need.remaining_quantity + 1, unit_ids: [item.id], reason: reason)
        end
        clear_allocation!(item)
        Mutation.audit!(item, actor: @actor, action: 'equipment_stock_released', changes: item.saved_changes.except('updated_at', 'lock_version'), reason: reason,
                              application_ids: [previous_application])
      end
      item
    end

    def swap!(item:, replacement_id:, expected_version:, replacement_version:, reason:)
      raise Conflict, 'Provide a swap reason.' if reason.to_s.strip.blank?

      item.transaction do
        replacement = EquipmentItem.find(replacement_id)
        lock_allocation!(item, replacement)
        Mutation.version!(item, expected_version)
        Mutation.version!(replacement, replacement_version)
        require_reserved!(item)
        Mutation.eligible_for_funding!(item.application, source: 'mat')
        unless EquipmentItem.available_stock.exists?(id: replacement.id, product_id: item.product_id)
          raise Conflict, 'Choose an available stock unit of the same exact model.'
        end

        snapshot = item.shipping_snapshot.merge(application_id: item.application_id, disability_setup_group: item.disability_setup_group,
                                                stock_allocated_at: item.stock_allocated_at, allocation_equipment_need_id: item.allocation_equipment_need_id,
                                                source_evaluation_id: item.source_evaluation_id)
        detached = EquipmentItem.find_by(replaced_by_equipment_item_id: item.id)
        if detached
          detached.update!(replaced_by_equipment_item: replacement)
          Mutation.audit!(detached, actor: @actor, action: 'equipment_replacement_updated',
                                    changes: detached.saved_changes.except('updated_at', 'lock_version'), reason: reason,
                                    application_ids: [item.application_id], equipment_item_ids: [detached.id, item.id, replacement.id])
        end
        clear_allocation!(item)
        replacement.allocation_mutation = true
        replacement.update!(snapshot)
        Mutation.audit!(replacement, actor: @actor, action: 'equipment_stock_swapped', changes: { replaced_unit_id: [item.id, replacement.id] }, reason: reason,
                                     application_ids: [replacement.application_id], equipment_item_ids: [item.id, replacement.id])
      end
      item
    end

    private

    def parsed_targets(needs, items)
      Array(needs).map do |attributes|
        row = attributes.to_h.symbolize_keys
        row[:quantity] = Integer(row[:quantity].to_s, 10)
        [EquipmentNeed, row]
      end + Array(items).map { |row| [EquipmentItem, row.to_h.symbolize_keys] }
    rescue ArgumentError, TypeError
      raise Conflict, 'Enter whole positive allocation quantities.'
    end

    def validate_targets!(targets)
      raise Conflict, 'Select requests to reserve for dispatch.' if targets.empty?
      return if targets.map { |type, row| [type.name, row[:id].to_s] }.uniq.size == targets.size

      raise Conflict, 'Select each request once.'
    end

    def lock_stock_selection!(targets)
      stock = select_stock!(targets)
      candidates = stock.values.flatten
      PurchaseOrder.where(id: candidates.filter_map(&:purchase_order_id)).order(:id).lock.load
      target_ids = targets.filter_map { |type, _row, target| target.id if type == EquipmentItem }
      expected_ids = (target_ids + candidates.map(&:id)).uniq
      locked = EquipmentItem.where(id: expected_ids).order(:id).lock.index_by(&:id)
      raise Conflict, 'Available stock changed. Review quantities; no partial allocation was made.' unless stock_selection_unchanged?(stock, locked, expected_ids)

      targets.each { |entry| entry[2] = locked.fetch(entry[2].id) if entry[0] == EquipmentItem }
      stock.transform_values { |units| units.map { |unit| locked.fetch(unit.id) } }
    end

    def select_stock!(targets)
      quantities = Hash.new(0)
      targets.each do |type, row, target|
        quantity = type == EquipmentNeed ? row[:quantity] : 1
        quantities[target.product_id] += quantity
      end
      quantities.to_h do |product_id, quantity|
        units = EquipmentItem.available_stock.where(product_id: product_id).order(:stock_received_on, :id).first(quantity)
        raise Conflict, 'Available stock changed. Review quantities; no partial allocation was made.' unless units.size == quantity

        [product_id, units]
      end
    end

    def stock_selection_unchanged?(stock, locked, expected_ids)
      candidate_ids = stock.values.flatten.map(&:id)
      available_ids = EquipmentItem.available_stock.where(id: candidate_ids).pluck(:id)
      locked.size == expected_ids.size && available_ids.sort == candidate_ids.sort && stock.all? do |product_id, units|
        units.all? { |unit| locked.fetch(unit.id).product_id == product_id }
      end
    end

    def allocate_target!(type, row, target, stock, confirm_discontinued, confirm_mat_funding)
      application = Application.find(target.application_id)
      quantity = type == EquipmentNeed ? row[:quantity] : 1
      review_target!(target, quantity, confirm_discontinued, confirm_mat_funding, row[:lock_version])
      setup = target.disability_setup_group

      stock = stock.fetch(target.product_id).shift(quantity)

      destination = target.is_a?(EquipmentNeed) ? application : target
      stock.each do |unit|
        unit.allocation_mutation = true
        unit.update!(destination.shipping_snapshot.merge(application: application, disability_setup_group: setup,
                                                         stock_allocated_at: Time.current, source_evaluation_id: target.source_evaluation_id,
                                                         allocation_equipment_need_id: (target.id if type == EquipmentNeed)))
        Mutation.audit!(unit, actor: @actor, action: 'equipment_stock_allocated', changes: unit.saved_changes.except('updated_at', 'lock_version'),
                              application_ids: [application.id], equipment_item_ids: [unit.id, (target.id if type == EquipmentItem)].compact)
      end
      if type == EquipmentNeed
        update_need_quantity!(target, target.remaining_quantity - quantity, unit_ids: stock.map(&:id), reason: 'Reserved devices from program stock.')
      else
        target.update!(withdrawn_at: Time.current, replaced_by_equipment_item: stock.fetch(0))
        Mutation.audit!(target, actor: @actor, action: 'equipment_replaced_with_stock', changes: target.saved_changes.except('updated_at', 'lock_version'),
                                application_ids: [application.id], equipment_item_ids: [target.id, *stock.map(&:id)])
      end
      stock
    end

    def review_target!(target, quantity, confirm_discontinued, confirm_mat_funding, expected_version)
      Mutation.version!(target, expected_version)
      application = target.application
      available = target.available_quantity
      raise Conflict, 'Remove bid reservations or refresh the requested quantity first.' unless quantity.positive? && quantity <= available
      if target.is_a?(EquipmentItem) && target.funding_source == 'icanconnect' && !confirm_mat_funding
        raise Conflict, 'Confirm replacing the iCanConnect-funded devices with MAT stock.'
      end
      raise Conflict, 'Confirm using owned discontinued stock for this exact-model request.' if target.product.archived? && !confirm_discontinued
      raise Conflict, 'Review this model eligibility against the confirmed program groups.' unless target.product.eligible_for?(application.program_disability_groups)

      setup = target.disability_setup_group
      destination = target.is_a?(EquipmentNeed) ? application : target
      return if destination.shipping_ready? && application.program_disability_groups.include?(setup)

      raise Conflict,
            'Review equipment: confirm destination and device setup.'
    end

    def update_need_quantity!(need, quantity, unit_ids:, reason:)
      fields = %w[id product_id remaining_quantity]
      before = need.attributes.slice(*fields)
      need.update!(remaining_quantity: quantity, unfulfilled_since: (need.remaining_quantity.zero? ? Time.current : need.unfulfilled_since))
      Mutation.audit!(need.application, actor: @actor, action: 'equipment_needs_updated',
                                        changes: { equipment_needs: [[before], [need.attributes.slice(*fields)]] }, reason: reason,
                                        application_ids: [need.application_id], equipment_need_ids: [need.id], equipment_item_ids: unit_ids)
    end

    def lock_allocation!(item, replacement = nil)
      application_id = item.application_id
      Mutation.lock_applications!([application_id].compact)
      EquipmentNeed.where(id: item.allocation_equipment_need_id).order(:id).lock.load
      PurchaseOrder.where(id: [item.purchase_order_id, replacement&.purchase_order_id].compact).order(:id).lock.load
      EquipmentItem.where(id: [item.id, replacement&.id].compact).order(:id).lock.load
      item.reload
      replacement&.reload
      raise Conflict, 'Allocation changed. Refresh before continuing.' unless application_id == item.application_id
    end

    def require_reserved!(item)
      return if item.stock? && item.application_id? && item.stock_received_on && !item.shipped_at? && !item.withdrawn_at?

      raise Conflict,
            'Only allocated, received, unshipped stock can be released or swapped.'
    end

    def clear_allocation!(item)
      item.allocation_mutation = true
      item.update!(EquipmentShipping::FIELDS.index_with(nil).merge(application: nil, disability_setup_group: nil, stock_allocated_at: nil,
                                                                   allocation_equipment_need: nil, source_evaluation: nil, setup_confirmed_at: nil))
    end
  end
end
