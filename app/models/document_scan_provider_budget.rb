# frozen_string_literal: true

class DocumentScanProviderBudget < ApplicationRecord
  # Pace actual HTTP requests, including redirects, below ten starts per minute.
  INTERVAL = 7.seconds

  validates :next_available_at, presence: true

  def self.wait_for_slot!
    loop do
      delay = try_reserve! - Time.current
      return if delay <= 0

      sleep [delay, INTERVAL].min
    end
  end

  # The singleton row paces submissions, polls, and redirects across workers.
  # A deferred caller does not consume another future slot when it wakes.
  def self.try_reserve!
    budget = create_or_find_by!(id: 1) { |record| record.next_available_at = Time.current }
    budget.with_lock do
      now = Time.current
      if budget.next_available_at <= now
        budget.update!(next_available_at: now + INTERVAL)
        now
      else
        budget.next_available_at
      end
    end
  end
end
