# frozen_string_literal: true

module Equipment
  class Correction
    class InvalidImpactToken < Conflict; end

    EDITABLE_ITEM_FIELDS = %w[product_id purchase_order_id shipped_at tracking_number carrier serial_number imei].freeze
    ITEM_FIELDS = (EDITABLE_ITEM_FIELDS + %w[withdrawn_at manufacturer_model_identity normalized_manufacturer normalized_imei normalized_serial_number]).freeze
    PO_FIELDS = %w[vendor_id number sent_at].freeze

    def self.impact_token(record:, attributes:, extra: {})
      Rails.application.message_verifier('equipment-impact').generate(impact_data(record, attributes, extra), expires_in: 30.minutes)
    end

    def self.impact_data(record, attributes, extra)
      [record.class.name, record.id, record.lock_version, confirmation_values(attributes), confirmation_values(extra)]
    end

    def self.confirmation_values(value)
      if value.respond_to?(:each_pair)
        value.to_h.stringify_keys.transform_values { |entry| confirmation_values(entry) }.tap do |values|
          %w[sent_at shipped_at].each { |field| values[field] = DateInputNormalizer.normalize(values[field])&.iso8601.to_s if values.key?(field) }
        end
      elsif value.is_a?(Array)
        value.map { |entry| confirmation_values(entry) }
      else
        value.to_s.strip
      end
    end

    def initialize(actor:)
      @actor = actor
      Mutation.authorize!(actor)
    end

    # Keep form versions, identity acknowledgment, and reviewed impact explicit at this write boundary.
    def update_item!(item:, attributes:, expected_version:, reason:, operation: 'update', confirmed_impact: false, # rubocop:disable Metrics/ParameterLists
                     purchase_order_versions: {}, new_purchase_order: nil, serial_duplicate_reason: nil, impact_token: nil)
      require_reason!(reason)
      attributes = attributes.to_h.stringify_keys.slice(*EDITABLE_ITEM_FIELDS)
      raise Conflict, 'Unknown equipment correction.' unless %w[update detach withdraw].include?(operation)

      EquipmentItem.transaction do
        application, orders, created_order = lock_item!(item, attributes, expected_version, operation == 'update' ? new_purchase_order : nil)
        previous = item.attributes.slice(*ITEM_FIELDS)
        require_unchanged_item_details!(item, attributes, new_purchase_order) unless operation == 'update'
        apply_item_operation!(item, operation, attributes, new_purchase_order: created_order)
        new_assignment = previous['purchase_order_id'].nil? && (item.purchase_order_id.present? || new_purchase_order.present?)
        Mutation.eligible!(application) if new_assignment && operation == 'update'
        if item.shipped_at_in_database.present?
          require_confirmation!(item, attributes, impact_token, confirmed_impact,
                                operation: operation, new_purchase_order: new_purchase_order || {})
        end
        assign_purchase_order!(item, orders, purchase_order_versions, created_order)
        require_available_product!(item) if item.will_save_change_to_product_id?
        item.serial_duplicate_reason = serial_duplicate_reason.to_s.strip.presence
        item.save!
        audit_item!(item, previous, reason, operation)
      end
      item
    rescue ActiveRecord::RecordNotUnique
      raise Conflict, 'A device identifier or vendor purchase order number is already assigned. Refresh and review the existing record.'
    end

    def update_purchase_order!(purchase_order:, attributes:, expected_version:, expected_item_versions:, reason:, confirmed_impact: false, impact_token: nil) # rubocop:disable Metrics/ParameterLists
      require_reason!(reason)
      membership = purchase_order.equipment_items.order(:id).pluck(:id, :application_id)
      PurchaseOrder.transaction do
        Mutation.lock_applications!(membership.map(&:last).uniq)
        purchase_order.reload(lock: true)
        items = purchase_order.equipment_items.order(:id).lock.to_a
        require_membership!(items, membership, expected_item_versions)
        Mutation.version!(purchase_order, expected_version)
        if items.size > 1 || items.any?(&:shipped_at?)
          require_confirmation!(purchase_order, attributes, impact_token, confirmed_impact, item_versions: expected_item_versions)
        end
        previous = purchase_order.attributes.slice(*PO_FIELDS)
        purchase_order.assign_attributes(attributes.to_h.stringify_keys.slice(*PO_FIELDS))
        purchase_order.save!
        items.each(&:validate!)
        changes = changed_values(previous, purchase_order.attributes.slice(*PO_FIELDS))
        if changes.any?
          Mutation.audit!(purchase_order, actor: @actor, action: 'equipment_purchase_order_corrected', changes: changes,
                                          reason: reason, application_ids: membership.map(&:last).uniq)
        end
      end
      purchase_order
    rescue ActiveRecord::RecordNotUnique
      raise Conflict, 'This vendor already has that purchase order number. Move the equipment to the existing purchase order.'
    end

    private

    def require_reason!(reason)
      raise Conflict, 'Provide a brief reason for this correction.' if reason.to_s.strip.blank?
    end

    def require_unchanged_item_details!(item, attributes, new_purchase_order)
      draft = EquipmentItem.new(attributes)
      changed = attributes.keys.any? { |field| draft.public_send(field) != item.public_send(field) }
      return unless changed || draft.rejected_shipped_at_input.present? || new_purchase_order.present?

      raise Conflict, 'Detach and withdraw do not change device details. Save device details separately.'
    end

    def lock_item!(item, attributes, expected_version, new_order_attributes)
      application = Mutation.lock_applications!([item.application_id]).fetch(0)
      item.reload
      Mutation.version!(item, expected_version)
      raise Conflict, 'Withdrawn equipment is retained as history.' if item.withdrawn_at?

      orders = PurchaseOrder.where(id: [item.purchase_order_id, attributes['purchase_order_id'].presence].compact).order(:id).lock.index_by(&:id)
      created_order = create_order!(new_order_attributes, application.id) if new_order_attributes.present?
      item.lock!
      Mutation.version!(item, expected_version)
      raise Conflict, 'Refresh the equipment item before changing its purchase order.' unless orders.key?(item.purchase_order_id) || item.purchase_order_id.nil?

      [application, orders, created_order]
    end

    def assign_purchase_order!(item, orders, versions, new_order)
      if new_order.present?
        item.purchase_order = new_order
      elsif item.purchase_order_id.present?
        selected = orders.fetch(item.purchase_order_id) { raise Conflict, 'The selected purchase order is unavailable.' }
        Mutation.version!(selected, versions[selected.id.to_s] || versions[selected.id]) if item.will_save_change_to_purchase_order_id?
        item.purchase_order = selected
      end
    end

    def audit_item!(item, previous, reason, operation)
      changes = changed_values(previous, item.attributes.slice(*ITEM_FIELDS))
      return if changes.empty?

      changes['serial_duplicate_reason'] = [nil, item.serial_duplicate_reason] if item.serial_duplicate_reason.present?
      Mutation.audit!(item, actor: @actor, action: 'equipment_item_corrected', changes: changes,
                            reason: reason, application_ids: [item.application_id], application_id: item.application_id,
                            purchase_order_ids: [previous['purchase_order_id'], item.purchase_order_id].compact.uniq,
                            correction: operation)
    end

    def require_membership!(items, membership, expected_versions)
      current_versions = items.to_h { |item| [item.id.to_s, item.lock_version.to_s] }
      matched = current_versions == expected_versions.to_h.stringify_keys.transform_values(&:to_s)
      matched &&= items.map { |item| [item.id, item.application_id] } == membership
      raise Conflict, 'Purchase order membership changed. Refresh and review its impact.' unless matched
    end

    def require_confirmation!(record, attributes, token, confirmed, **extra)
      expected = self.class.impact_data(record, attributes, extra)
      observed = Rails.application.message_verifier('equipment-impact').verified(token)
      raise InvalidImpactToken, 'This correction review is no longer valid. Review the current values again before saving.' unless observed

      raise Conflict, 'Review the current correction values and confirm their impact before saving.' unless confirmed && observed == expected
    end

    def apply_item_operation!(item, operation, attributes, new_purchase_order:)
      if operation == 'update'
        if item.purchase_order_id? && attributes.key?('purchase_order_id') && attributes['purchase_order_id'].blank? && new_purchase_order.nil?
          raise Conflict, 'Use the detach action to remove an unshipped device from its purchase order.'
        end

        item.assign_attributes(attributes)
      else
        raise Conflict, 'Shipped equipment cannot be detached or withdrawn. Correct the ship date first with impact confirmation.' if item.shipped_at?
        raise Conflict, 'Only detached equipment can be withdrawn.' if operation == 'withdraw' && item.purchase_order_id?

        item.purchase_order = nil
        item.withdrawn_at = Time.current if operation == 'withdraw'
      end
    end

    def create_order!(attributes, application_id)
      order = PurchaseOrder.create!(attributes.to_h.stringify_keys.slice(*PO_FIELDS))
      Mutation.audit!(order, actor: @actor, action: 'equipment_purchase_order_recorded', changes: changed_values({}, order.attributes.slice(*PO_FIELDS)),
                             application_ids: [application_id])
      order
    end

    def require_available_product!(item)
      raise Conflict, 'Select an available catalog product.' unless item.product && !item.product.archived?
    end

    def changed_values(previous, current)
      current.filter_map { |field, value| [field, { old: previous[field], new: value }] if previous[field] != value }.to_h
    end
  end
end
