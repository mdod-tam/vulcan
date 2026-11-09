# frozen_string_literal: true

# Security budgets cannot reset when the shared cache evicts an entry.
class AuthRateLimitCounter < ApplicationRecord
  def self.reserve!(key:, period:, now: Time.current)
    transaction do
      counter = create_or_find_by!(key: key) { |row| row.expires_at = now + period }
      counter.lock!
      counter.assign_attributes(attempts: 0, expires_at: now + period) if counter.expires_at <= now
      counter.attempts += 1
      counter.save!
      counter.attempts
    end
  end

  def self.usage(key, now: Time.current)
    where(key: key).where('expires_at > ?', now).pick(:attempts) || 0
  end
end
