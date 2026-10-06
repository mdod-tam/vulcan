# frozen_string_literal: true

# Failed date-of-birth guesses for one voucher by one vendor. Kept in the database, not the session
# or cache: signing out must not reset it, and the row lock serializes parallel guesses.
#
# Failures count within a window that starts at the first one. Reaching the limit locks this
# vendor out of this voucher for PERIOD; other vendors are unaffected, so no vendor can lock a
# constituent out everywhere.
class VoucherVerificationThrottle < ApplicationRecord
  PERIOD = 30.minutes

  belongs_to :voucher
  belongs_to :vendor, class_name: 'User'

  def self.locked_until_for(voucher, vendor, now: Time.current)
    find_by(voucher: voucher, vendor: vendor)&.locked_until&.then { |time| time if time > now }
  end

  # Yields this pair's row, locked for the rest of the transaction, with an expired window cleared.
  def self.with_row_lock(voucher, vendor, now: Time.current)
    transaction do
      throttle = create_or_find_by!(voucher: voucher, vendor: vendor)
      throttle.lock!
      throttle.clear_window if throttle.window_expired?(now)
      yield throttle
    end
  end

  def locked?(now = Time.current)
    locked_until.present? && locked_until > now
  end

  def window_expired?(now)
    !locked?(now) && window_started_at.present? && window_started_at <= now - PERIOD
  end

  def clear_window
    assign_attributes(failed_attempts: 0, window_started_at: nil, locked_until: nil)
  end

  def record_failure!(max_attempts, now = Time.current)
    self.window_started_at ||= now
    self.failed_attempts += 1
    self.locked_until = now + PERIOD if failed_attempts >= max_attempts
    save!
  end
end
