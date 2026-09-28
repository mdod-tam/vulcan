# frozen_string_literal: true

module EmailDelivery
  # Maps a Postmark message status to a Notification delivery_status. Postmark's Queued, Sent, and
  # Processed mean the provider has the message, not that the recipient received it, so they map to
  # queued or submitted; only a delivery or open timestamp means delivered or opened. Anything else
  # is reported as unrecognized and leaves the stored status alone.
  # https://postmarkapp.com/developer/api/messages-api
  module ProviderStatus
    PROVIDER_STATUSES = {
      'queued' => 'queued',
      'sent' => 'submitted',
      'processed' => 'submitted'
    }.freeze

    # A poll never moves a notification backward, e.g. from opened to submitted.
    RANK = { 'queued' => 1, 'submitted' => 2, 'delivered' => 3, 'opened' => 4 }.freeze

    Result = Data.define(:status, :recognized)

    module_function

    def normalize(raw_status:, delivered_at: nil, opened_at: nil)
      return Result.new(status: 'opened', recognized: true) if opened_at.present?
      return Result.new(status: 'delivered', recognized: true) if delivered_at.present?

      mapped = PROVIDER_STATUSES[raw_status.to_s.downcase]
      Result.new(status: mapped, recognized: mapped.present?)
    end

    def advance(current, candidate)
      return current if candidate.nil?
      return candidate if current.nil?
      return current unless RANK.key?(current)

      RANK.fetch(candidate, 0) > RANK.fetch(current) ? candidate : current
    end
  end
end
