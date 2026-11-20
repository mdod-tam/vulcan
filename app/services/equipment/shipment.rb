# frozen_string_literal: true

module Equipment
  class Shipment
    class SelectionChanged < Conflict; end

    def initialize(actor: nil, vendor_request: nil)
      @actor = actor
      @vendor_request = vendor_request
      Mutation.authorize!(actor) unless vendor_request
    end

    def call(rows:, attributes:, confirm_setup: false)
      rows = rows.map { |row| row.to_h.with_indifferent_access }
      ids = rows.map { |row| row[:id].to_s }
      raise Conflict, 'Select the devices in this package.' if ids.empty?
      raise SelectionChanged, 'Select each device once.' if ids.uniq.size != ids.size

      rows_by_id = rows.index_by { |row| row[:id].to_s }

      EquipmentItem.transaction do
        items = lock_selection!(ids)
        attributes = shipment_attributes(attributes)
        verify_vendor_request! if @vendor_request
        next items if @vendor_request && already_recorded?(items, attributes)

        items.each { |item| verify_unit!(item, rows_by_id.fetch(item.id.to_s)) }
        require_group!(items)

        items.each do |item|
          prepare_unit!(item, rows_by_id.fetch(item.id.to_s), attributes, confirm_setup)
        end
        save_shipments!(items)
      end
    end

    private

    def lock_selection!(ids)
      scope = EquipmentItem.where(id: ids).order(:id)
      scope = scope.direct_vendor.where(purchase_order_id: @vendor_request.purchase_order_id) if @vendor_request
      membership = scope.pluck(:id, :application_id, :purchase_order_id)
      Mutation.lock_applications!(membership.pluck(1).compact.uniq)
      PurchaseOrder.where(id: membership.map(&:last).compact).order(:id).lock.load
      items = scope.includes(:application, :product).lock.to_a
      current = items.map { |item| [item.id, item.application_id, item.purchase_order_id] }
      raise SelectionChanged, 'Shipment membership changed. Select the devices again.' unless items.size == ids.size && current == membership

      items
    end

    def save_shipments!(items)
      actor = @vendor_request ? PublicAuditActor.system_audit_actor! : @actor
      EquipmentItem.lock_identity_assignments!(items)
      items.each do |item|
        item.save!
        Mutation.audit!(item, actor: actor, action: 'equipment_shipment_recorded', changes: item.previous_changes.except('updated_at'),
                              application_ids: [item.application_id], purchase_order_ids: [item.purchase_order_id].compact,
                              **(@vendor_request&.audit_identity || {}))
      end
    end

    def shipment_attributes(attributes)
      values = attributes.to_h.symbolize_keys
      values[:shipped_at] = DateInputNormalizer.normalize(values[:shipped_at])
      raise Conflict, 'Enter an actual shipment date.' unless values[:shipped_at]
      raise Conflict, 'Choose the carrier.' if @vendor_request && values[:carrier].blank?

      values
    end

    def verify_vendor_request!
      @vendor_request.reload(lock: true)
      raise SelectionChanged, 'This vendor link is no longer available.' unless @vendor_request.active_for_public_use?
    end

    def already_recorded?(items, attributes)
      items.all? do |item|
        item.shipped_at == attributes[:shipped_at] &&
          item.carrier == attributes[:carrier].to_s.strip.presence &&
          item.tracking_number == attributes[:tracking_number].to_s.strip.presence
      end
    end

    def require_group!(items)
      destinations = items.map { |item| [item.application.user_id, item.fulfillment_source == 'direct_vendor', item.shipping_snapshot] }.uniq
      raise SelectionChanged, 'One shipment must have one beneficiary, destination and fulfillment source.' unless destinations.one?
    end

    def verify_unit!(item, row)
      Mutation.version!(item, row[:lock_version])
      raise Conflict, 'This unit is no longer awaiting shipment.' unless item.awaiting_shipment? && item.application.status_approved?
    rescue Conflict => e
      raise SelectionChanged, e.message
    end

    def prepare_unit!(item, row, attributes, confirm_setup)
      raise Conflict, 'Confirm the constituent setup before packing stock.' if item.stock? && !confirm_setup

      values = attributes.to_h.symbolize_keys.slice(:shipped_at, :tracking_number, :carrier)
      item.assign_attributes(values)
      return if @vendor_request

      %i[serial_number imei].each do |field|
        next if row[field].blank?
        if item.public_send(field).present? && item.public_send(field) != row[field]
          raise Conflict,
                'A known physical identifier cannot be overwritten at packing. Swap units or use a reviewed correction.'
        end

        item.public_send("#{field}=", row[field])
      end
      item.setup_confirmed_at = Time.current if item.stock?
    end
  end
end
