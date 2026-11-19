# frozen_string_literal: true

module Equipment
  class StockReceipt
    EXISTING_STOCK_ACTION = 'equipment_existing_stock_recorded'
    OPERATION_ID_FORMAT = /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/

    def initialize(actor:)
      @actor = actor
      Mutation.authorize!(actor)
    end

    def receive!(order:, received_on:, rows:, expected_version:, item_versions:)
      received_on = DateInputNormalizer.normalize(received_on)
      raise Conflict, 'Enter an actual received date.' unless received_on

      rows = parsed_receipt_rows(rows)
      batches = rows.pluck(:batch)
      raise Conflict, 'Receive each order line once per save.' unless batches.uniq.size == batches.size

      order.transaction do
        order.lock!
        Mutation.version!(order, expected_version)
        raise Conflict, 'Receive against a sent Program stock PO.' unless order.program_stock? && order.sent_at

        items = order.equipment_items.active.where(stock_received_on: nil).includes(:product).order(:id).lock.to_a
        versions = items.to_h { |item| [item.id.to_s, item.lock_version.to_s] }
        unless versions == item_versions.to_h.stringify_keys.transform_values(&:to_s)
          raise Conflict,
                'Outstanding stock changed. Review the refreshed counts and your attempted quantities.'
        end

        received = receive_rows!(items.group_by(&:stock_receipt_batch), rows, received_on)
        raise Conflict, 'Receive at least one unit.' if received.empty?

        received.each do |item|
          Mutation.audit!(item, actor: @actor, action: 'equipment_stock_received', changes: item.previous_changes.except('updated_at'),
                                purchase_order_ids: [order.id], equipment_item_ids: [item.id])
        end
      end
      order
    end

    def existing!(product:, quantity:, received_on:, provenance:, identifiers: [], operation_id: SecureRandom.uuid)
      raise Conflict, 'Open a new stock form before recording this intake.' unless OPERATION_ID_FORMAT.match?(operation_id.to_s)

      raise Conflict, 'Resolve the exact model before recording existing stock.' unless product.model_confirmed?
      raise Conflict, 'Describe verified existing-stock provenance.' if provenance.to_s.strip.blank?

      received_on = DateInputNormalizer.normalize(received_on)
      raise Conflict, 'Enter an actual received date.' unless received_on

      count = begin
        Integer(quantity.to_s, 10)
      rescue ArgumentError, TypeError
        raise Conflict, 'Enter a positive whole stock quantity.'
      end
      raise Conflict, 'Enter a positive whole stock quantity.' unless count.positive?

      identifiers = Array(identifiers).map { |entry| entry.to_h.symbolize_keys.slice(:serial_number, :imei) }
      EquipmentItem.transaction do
        lock_intake!(operation_id)
        prior_ids = Event.where(user: @actor, action: EXISTING_STOCK_ACTION, auditable_type: 'EquipmentItem')
                         .with_metadata(:operation_id, operation_id).pluck(:auditable_id)
        next EquipmentItem.where(id: prior_ids).order(:id).to_a if prior_ids.any?

        created = count.times.map do |index|
          EquipmentItem.new(identifiers.fetch(index, {})
                                      .merge(product: product, fulfillment_source: 'existing_stock', stock_received_on: received_on,
                                             intake_provenance: provenance.to_s.strip, funding_source: 'mat'))
        end
        EquipmentItem.lock_identity_assignments!(created)
        created.each do |item|
          item.save!
          Mutation.audit!(item, actor: @actor, action: EXISTING_STOCK_ACTION, changes: item.previous_changes.except('created_at', 'updated_at'),
                                reason: provenance, operation_id: operation_id)
        end
        created
      end
    end

    private

    # The committed audit events identify the units created by a retried form.
    def lock_intake!(operation_id)
      key = "equipment-stock-intake:#{@actor.id}:#{operation_id}"
      bind = ActiveRecord::Relation::QueryAttribute.new('key', key, ActiveRecord::Type::String.new)
      EquipmentItem.connection.exec_query('SELECT pg_advisory_xact_lock(hashtextextended($1, 0))::text', 'Existing stock intake lock', [bind])
    end

    def parsed_receipt_rows(rows)
      Array(rows).map do |attributes|
        row = attributes.to_h.symbolize_keys
        row[:quantity] = Integer(row[:quantity].to_s, 10)
        row[:identifiers] = Array(row[:identifiers]).map { |entry| entry.to_h.symbolize_keys.slice(:serial_number, :imei) }
        row
      end
    rescue ArgumentError, TypeError
      raise Conflict, 'Enter whole receiving quantities.'
    end

    def receive_rows!(batches, rows, received_on)
      received = []
      rows.each do |row|
        quantity = row[:quantity]
        next if quantity.zero?

        available = batches.fetch(row[:batch], [])
        raise Conflict, 'Receiving quantities must be whole numbers within the outstanding balance.' unless quantity.between?(0, available.size)

        available.first(quantity).each_with_index do |item, index|
          identifiers = row[:identifiers].fetch(index, {})
          item.assign_attributes(identifiers.merge(stock_received_on: received_on))
          received << item
        end
      end
      EquipmentItem.lock_identity_assignments!(received)
      received.each(&:save!)
      received
    end
  end
end
