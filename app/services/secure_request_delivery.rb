# frozen_string_literal: true

class SecureRequestDelivery
  # Keep the unsent link and its tracking outcome consistent. Workflow compensation
  # and cooldown rules remain with the issuing service.
  def self.suppress!(request_form:, notification:, actor:, reason:, channel: :email)
    request_form.with_lock do
      notification&.mark_delivery_suppressed!(reason, channel: channel)
      request_form.revoke!(actor: actor, reason: :delivery_suppressed, metadata: { suppression_reason: reason })
    end
  end
end
