# frozen_string_literal: true

class DocumentScanProviderBudget < ApplicationRecord
  # One operation can make three HTTP requests while following provider redirects.
  INTERVAL = 21.seconds

  validates :next_available_at, presence: true

  # The singleton row paces submissions and polls across worker processes.
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
