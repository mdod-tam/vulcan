# frozen_string_literal: true

module EmailDelivery
  module Routing
    def self.prefers_letter?(recipient, override: nil)
      return override.to_s == 'letter' if override.present?

      preference = if recipient.respond_to?(:effective_communication_preference)
                     recipient.effective_communication_preference
                   elsif recipient.respond_to?(:communication_preference)
                     recipient.communication_preference
                   end
      preference.to_s == 'letter'
    end
  end
end
