# frozen_string_literal: true

module EmailDelivery
  # The context captured when a queued email was requested, visible to the mailer while
  # the delivery job runs. queued is true inside that job, so a missing context there means
  # the job was queued without one and must not borrow the current settings. A refusal keeps
  # the complete policy decision; its reason alone cannot distinguish suppression from an error.
  class Current < ActiveSupport::CurrentAttributes
    # notification_id: the Notification an email is being sent for, recorded in its context so a
    # later suppression can be written back to it.
    attribute :context, :queued, :denial_decision, :notification_id

    def denial_reason = denial_decision&.reason
  end
end
