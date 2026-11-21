# frozen_string_literal: true

module Equipment
  module ShipmentNotice
    ACTION = 'equipment_shipment_notice'

    module_function

    def record!(items, actor:, corrected: false)
      key = package_key(items.first)
      lock_package!(key)
      notified = Notification.where(action: ACTION).where("metadata->>'package_key' = ?", key).pluck(:recipient_id).to_set
      items.uniq(&:application_id).each do |item|
        contact = Applications::ContactContext.new(application: item.application)
        recipient = contact.email_owner || contact.preference_owner
        next unless notified.add?(recipient.id)

        notice = NotificationService.create_and_deliver!(
          type: ACTION, recipient: recipient, actor: actor, notifiable: item.application, audit: true, deliver: contact.email.present?,
          metadata: { package_key: key, equipment_item_id: item.id, contact_key: contact_key(contact), corrected: corrected }
        )
        notice.mark_delivery_suppressed!(:missing_recipient) if contact.email.blank?
      end
    end

    def package_key(item)
      number = item.tracking_number.to_s.gsub(/[[:space:]]+/, '').upcase
      secret = Rails.application.key_generator.generate_key('equipment-shipment-package')
      OpenSSL::HMAC.hexdigest('SHA256', secret, [item.application.user_id, item.shipped_at, number].to_json)
    end

    def contact_key(contact)
      EmailDeliveryAttempt.recipient_key(contact.email) if contact.email.present?
    end

    # A package can be recorded in separate saves, including saves on different applications.
    def lock_package!(key)
      value = [key].pack('H*').unpack1('q>')
      bind = ActiveRecord::Relation::QueryAttribute.new('key', value, ActiveRecord::Type::BigInteger.new)
      Notification.connection.exec_query('SELECT pg_advisory_xact_lock($1)::text', 'Shipment notice lock', [bind])
    end
    private_class_method :lock_package!
  end
end
