# frozen_string_literal: true

module VoucherTransactions
  # The one writer for how a purchase is fulfilled: its fulfillment mode and its packages.
  #
  # Each operation locks the purchase row, refuses anything but a completed redemption, compares the
  # version the caller saw, and writes the change and its audit event together or not at all.
  # Money, ownership, status, and invoice links are never touched here. A recorded package is
  # tracking the vendor reports, not proof of dispatch, delivery, or acceptance; nothing is sent about it.
  class FulfillmentService
    # The caller's form was out of date: someone else changed this purchase or package first.
    class StaleError < StandardError; end
    class NotFulfillableError < StandardError; end

    SHIPMENT_FIELDS = %w[tracking_number dispatched_on contents].freeze

    def initialize(transaction:, actor:)
      @transaction = transaction
      @actor = actor
    end

    # Choosing the mode the purchase already has changes nothing: no new version, no audit event.
    def change_mode!(mode:, expected_version:)
      locked_purchase do |purchase|
        check_version!(purchase, expected_version)
        previous = purchase.fulfillment_mode
        if previous != mode.to_s
          purchase.update!(fulfillment_mode: mode, fulfillment_version: purchase.fulfillment_version + 1)
          audit!(purchase, 'fulfillment_mode_changed', 'fulfillment_mode' => { 'old' => previous, 'new' => mode.to_s })
        end
        purchase
      end
    end

    # Recording a package means the purchase ships; a pickup or unspecified purchase becomes shipping.
    # Earlier packages always remain as history.
    def add_shipment!(attributes:, expected_version:)
      locked_purchase do |purchase|
        check_version!(purchase, expected_version)
        shipment = purchase.shipments.create!(attributes.to_h.slice(*SHIPMENT_FIELDS).merge(created_by: @actor))
        changes = SHIPMENT_FIELDS.select { |field| shipment[field].present? }
                                 .index_with { |field| { 'old' => nil, 'new' => shipment[field].to_s } }
        unless purchase.fulfillment_shipping?
          changes['fulfillment_mode'] = { 'old' => purchase.fulfillment_mode, 'new' => 'shipping' }
          purchase.fulfillment_mode = :shipping
        end
        purchase.update!(fulfillment_version: purchase.fulfillment_version + 1)
        audit!(purchase, 'shipment_added', changes, shipment_id: shipment.id)
        shipment
      end
    end

    def correct_shipment!(shipment_id:, attributes:, expected_lock_version:)
      locked_purchase do |purchase|
        shipment = purchase.shipments.find(shipment_id)
        raise StaleError unless shipment.lock_version == expected_lock_version.to_i

        shipment.update!(attributes.to_h.slice(*SHIPMENT_FIELDS).merge(updated_by: @actor))
        changes = shipment.saved_changes.slice(*SHIPMENT_FIELDS).transform_values do |old, new|
          { 'old' => old&.to_s, 'new' => new&.to_s }
        end
        audit!(purchase, 'shipment_corrected', changes, shipment_id: shipment.id) if changes.any?
        shipment
      end
    rescue ActiveRecord::StaleObjectError
      raise StaleError
    end

    private

    def locked_purchase
      ActiveRecord::Base.transaction do
        purchase = VoucherTransaction.lock.find(@transaction.id)
        raise NotFulfillableError unless purchase.fulfillable?

        yield purchase
      end
    end

    def check_version!(purchase, expected_version)
      raise StaleError unless purchase.fulfillment_version == expected_version.to_i
    end

    # A distinct operation id keeps each change, even two in quick succession, from being deduplicated.
    # voucher_id puts the event in the admin voucher page's audit log (Vouchers::VoucherAuditLogBuilder).
    def audit!(purchase, action, changes, extra = {})
      AuditEventService.log(
        action: action, actor: @actor, auditable: purchase,
        metadata: { changes: changes, operation_id: SecureRandom.uuid, voucher_id: purchase.voucher_id }.merge(extra)
      )
    end
  end
end
