# frozen_string_literal: true

module Equipment
  class VendorOrder
    def initialize(actor:)
      Mutation.authorize!(actor)
      @actor = actor
    end

    def send!(order:, attributes:, expected_version:)
      denial, context = EmailDelivery.issuance(PurchaseOrderShippingRequest::MAIL_ACTION)
      raise Conflict, 'Vendor email is unavailable. Check communication settings before sending this PO.' if denial

      initial_send = !order.sent_at?
      issued = PurchaseOrder.transaction do
        release!(order, expected_version)
        request = SecureFormReplacement.replace!(
          open: order.shipping_requests.open, actor: @actor,
          attributes: attributes.merge(purchase_order: order, expires_at: PurchaseOrderShippingRequest::LINK_LIFETIME.from_now)
        )
        Mutation.audit!(order, actor: @actor, action: 'equipment_vendor_link_issued', changes: {}, **request.secure_request_form.audit_metadata)
        request
      end

      deliver(issued, context, initial_send_version: (order.lock_version if initial_send))
    rescue Applications::SecureRequestIssuance::CooldownActive
      raise Conflict, 'A link was sent recently. Wait before sending another or revoke it to correct the recipient.'
    rescue ActiveRecord::StaleObjectError
      raise Conflict, 'This PO changed. Review it before sending.'
    end

    def revoke!(order:, request_id:)
      order.with_lock do
        request = order.shipping_requests.open.find_by(id: request_id)
        raise Conflict, 'The current vendor link has changed.' unless request

        request.revoke!(actor: @actor)
        order.update!(updated_at: Time.current)
      end
    end

    private

    def release!(order, expected_version)
      if order.sent_at?
        order.lock!
        Mutation.version!(order, expected_version)
        Ordering.verify_shipping_details!(order)
        order.update!(updated_at: Time.current)
      else
        Ordering.new(actor: @actor).mark_sent!(order: order, sent_at: Date.current, expected_version: expected_version)
      end
      raise Conflict, 'Vendor links are for orders shipping directly to recipients.' unless order.direct_to_constituents?
      raise Conflict, 'Enter the vendor name before sending this order.' if order.vendor_name.blank?
      raise Conflict, 'There are no devices left to ship on this PO.' unless order.equipment_items.active.direct_vendor.exists?(shipped_at: nil)
    end

    def deliver(issued, context, initial_send_version:)
      request = issued.secure_request_form
      begin
        url = SecureFormPolicy.public_url(:secure_vendor_order_url, issued.raw_token)
        EmailDelivery.deliver_now!(VendorNotificationsMailer.equipment_order(request, url), context: context)
      rescue StandardError => e
        Rails.logger.warn("Vendor PO email for request #{request.id} failed: #{e.class.name}")
        record_failure!(request, initial_send_version)
        return request
      end

      request.update!(delivery_status: :sent)
      request
    end

    def record_failure!(request, initial_send_version)
      order = request.purchase_order
      order.with_lock do
        request.update!(delivery_status: :failed)
        request.revoke!(actor: @actor, reason: :email_failed)
        next unless order.lock_version == initial_send_version
        next if order.equipment_items.where.not(shipped_at: nil).exists?

        order.update!(sent_at: nil)
        Mutation.audit!(order, actor: @actor, action: 'equipment_vendor_email_failed', changes: order.saved_changes.slice('sent_at'),
                               **request.audit_metadata)
      end
    end
  end
end
