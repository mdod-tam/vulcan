# frozen_string_literal: true

module Applications
  class PostalRequestClosure
    # The response writer holds the application lock and owns the transaction.
    def self.fulfill!(application:, kind:, actor:)
      requests = application.secure_request_forms.open_requests.recipient_channel_letter.where(kind: kind)
      close!(requests, actor: actor, reason: :fulfilled_by_staff)
    end

    def self.revoke!(application:, requests:, actor:, reason:)
      application.with_lock do
        close!(requests.operator_revocable, actor: actor, reason: reason)
      end
    end

    def self.close!(requests, actor:, reason:)
      closed = requests.order(:id).lock.select { |request| request.revoke!(actor: actor, reason: reason) }
      Letters::Delivery.cancel_closed_requests!(closed.select(&:recipient_channel_letter?).map(&:id), actor: actor)
      closed.size
    end
    private_class_method :close!
  end
end
