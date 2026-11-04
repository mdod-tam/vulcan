# frozen_string_literal: true

class CleanupExpiredSessionsJob < ApplicationJob
  queue_as :low

  def perform
    Session.expired_at(Time.current).in_batches(of: 500) do |sessions|
      # Reapply both deadlines at deletion, after a candidate may have refreshed its activity.
      sessions.merge(Session.expired_at(Time.current)).delete_all
    end
  end
end
