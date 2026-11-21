# frozen_string_literal: true

module Equipment
  class Correction
    class InvalidImpactToken < Conflict; end

    EDITABLE_ITEM_FIELDS = (%w[product_id shipped_at stock_received_on tracking_number carrier serial_number imei disability_setup_group] + EquipmentShipping::FIELDS).freeze
    ITEM_FIELDS = (EDITABLE_ITEM_FIELDS + %w[purchase_order_id withdrawn_at unfulfilled_since manufacturer_model_identity normalized_manufacturer normalized_imei
                                             normalized_serial_number]).freeze
    PO_FIELDS = (%w[number sent_at] + EquipmentShipping::FIELDS).freeze

    def self.impact_token(record:, attributes:, extra: {})
      Rails.application.message_verifier('equipment-impact').generate(impact_data(record, attributes, extra), expires_in: 30.minutes)
    end

    def self.impact_data(record, attributes, extra)
      [record.class.name, record.id, record.lock_version, confirmation_values(attributes), confirmation_values(extra)]
    end

    def self.confirmation_values(value)
      if value.respond_to?(:each_pair)
        value.to_h.stringify_keys.transform_values { |entry| confirmation_values(entry) }.tap do |values|
          %w[sent_at shipped_at stock_received_on].each { |field| values[field] = DateInputNormalizer.normalize(values[field])&.iso8601.to_s if values.key?(field) }
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

    # Keep form versions and reviewed changes explicit at this write boundary.
    def update_item!(item:, attributes:, expected_version:, reason:, operation: 'update', confirmed_impact: false, # rubocop:disable Metrics/ParameterLists
                     impact_token: nil, notify_tracking: false)
      require_reason!(reason)
      raise Conflict, 'Assign purchase orders through bid award.' if attributes.to_h.key?('purchase_order_id') || attributes.to_h.key?(:purchase_order_id)

      attributes = attributes.to_h.stringify_keys.slice(*EDITABLE_ITEM_FIELDS)
      raise Conflict, 'Unknown equipment correction.' unless %w[update detach withdraw].include?(operation)

      EquipmentItem.transaction do
        lock_item!(item, expected_version)
        raise Conflict, 'Amend the active bid reservation first.' if item.bid_group_lines.reserved.exists?

        previous = item.attributes.slice(*ITEM_FIELDS)
        require_unchanged_item_details!(item, attributes) unless operation == 'update'
        apply_item_operation!(item, operation, attributes)
        if item.shipped_at_in_database.present?
          require_confirmation!(item, attributes, impact_token, confirmed_impact,
                                operation: operation)
        end
        validate_product_correction!(item)
        item.save!
        if previous['purchase_order_id'] && previous['purchase_order_id'] != item.purchase_order_id
          PurchaseOrder.find(previous['purchase_order_id']).update!(updated_at: Time.current)
        end
        audit_item!(item, previous, reason, operation)
        record_shipment_notice(item, previous, notify_tracking)
      end
      item
    rescue ActiveRecord::RecordNotUnique
      raise Conflict, 'A device identifier is already assigned. Refresh and review the existing record.'
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
        previous = purchase_order.attributes.slice(*PO_FIELDS)
        values = attributes.to_h.stringify_keys
        confirm_po_change!(purchase_order, items, values, expected_item_versions, impact_token, confirmed_impact)
        purchase_order.assign_attributes(values.slice(*PO_FIELDS))
        purchase_order.save!
        items.each(&:validate!)
        if purchase_order.saved_change_to_sent_at? && !purchase_order.sent_at?
          purchase_order.shipping_requests.open.order(:id).each { |request| request.revoke!(actor: @actor, reason: :purchase_order_unsent) }
        end
        changes = changed_values(previous, purchase_order.attributes.slice(*PO_FIELDS))
        if changes.any?
          Mutation.audit!(purchase_order, actor: @actor, action: 'equipment_purchase_order_corrected', changes: changes,
                                          reason: reason, application_ids: membership.map(&:last).compact.uniq, equipment_item_ids: items.map(&:id),
                                          purchase_order_ids: [purchase_order.id])
        end
      end
      purchase_order
    rescue ActiveRecord::RecordNotUnique
      raise Conflict, 'This PO number is already recorded. Review the existing purchase order.'
    end

    private

    def record_shipment_notice(item, previous, notify_tracking)
      return unless item.shipped_at? && item.application&.status_approved?

      corrected = previous['shipped_at'].present?
      return if corrected && (!notify_tracking || previous['tracking_number'] == item.tracking_number)

      ShipmentNotice.record!([item], actor: @actor, corrected:)
    end

    def confirm_po_change!(purchase_order, items, attributes, versions, token, confirmed)
      if items.size > 1 || items.any?(&:shipped_at?) || (purchase_order.sent_at && attributes['sent_at'].blank?)
        require_confirmation!(purchase_order, attributes, token, confirmed, item_versions: versions)
      end
      return unless purchase_order.sent_at && attributes.key?('sent_at') && attributes['sent_at'].blank?
      return if attributes['unsend'] == '1' && confirmed

      raise Conflict, 'Explicitly acknowledge the constituent visibility change before clearing a false sent date.'
    end

    def require_reason!(reason)
      raise Conflict, 'Provide a brief reason for this correction.' if reason.to_s.strip.blank?
    end

    def require_unchanged_item_details!(item, attributes)
      draft = EquipmentItem.new(attributes)
      changed = attributes.keys.any? { |field| draft.public_send(field) != item.public_send(field) }
      return unless changed || draft.rejected_shipped_at_input.present?

      raise Conflict, 'Detach and withdraw do not change device details. Save device details separately.'
    end

    def lock_item!(item, expected_version)
      original_application_id = item.application_id
      original_order_id = item.purchase_order_id
      Mutation.lock_applications!([original_application_id].compact)
      PurchaseOrder.where(id: original_order_id).order(:id).lock.load
      item.reload
      item.lock!
      Mutation.version!(item, expected_version)
      unless original_application_id == item.application_id && original_order_id == item.purchase_order_id
        raise Conflict, 'Device allocation changed. Refresh before correcting.'
      end
      raise Conflict, 'Withdrawn equipment is retained as history.' if item.withdrawn_at?
    end

    def audit_item!(item, previous, reason, operation)
      changes = changed_values(previous, item.attributes.slice(*ITEM_FIELDS))
      return if changes.empty?

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

    def apply_item_operation!(item, operation, attributes)
      return item.assign_attributes(attributes) if operation == 'update'

      require_disposition_change!(item, operation)
      if item.direct_vendor?
        item.purchase_order = nil
        item.unfulfilled_since = Time.current if operation == 'detach'
      end
      item.withdrawn_at = Time.current if operation == 'withdraw'
    end

    def require_disposition_change!(item, operation)
      raise Conflict, 'Shipped equipment cannot be detached or withdrawn. Correct the ship date first with impact confirmation.' if item.shipped_at?
      raise Conflict, 'Filed costs and shared invoice evidence must be corrected before removing this device.' if item.icc_financial_evidence_locked?
      raise Conflict, 'Release stock allocation before withdrawing it.' if item.stock? && item.application_id?
      raise Conflict, 'Stock acquisition POs cannot be detached.' if item.stock? && operation == 'detach'
      raise Conflict, 'Only detached direct equipment can be withdrawn.' if operation == 'withdraw' && item.direct_vendor? && item.purchase_order_id?
    end

    def validate_product_correction!(item)
      return unless item.will_save_change_to_product_id?
      raise Conflict, 'Release the stock allocation before correcting its exact model.' if item.stock? && item.application_id?

      require_available_product!(item)
    end

    def require_available_product!(item)
      raise Conflict, 'Select an available catalog product.' unless item.product&.available?
    end

    def changed_values(previous, current)
      current.filter_map { |field, value| [field, { old: previous[field], new: value }] if previous[field] != value }.to_h
    end
  end
end
