# frozen_string_literal: true

module EmailDelivery
  class PollJob < ApplicationJob
    queue_as :default

    def perform
      EmailDeliveryAttempt.pollable.where(server_id: ENV.fetch('POSTMARK_SERVER_ID', 'default'))
                          .order(Arel.sql('last_checked_at ASC NULLS FIRST, id ASC')).limit(100).each { |attempt| PostmarkEmailTracker.refresh(attempt) }
    end
  end
end
