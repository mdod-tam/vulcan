# frozen_string_literal: true

module Equipment
  class WaitTime
    def self.days_since(entered_at, now: Time.current)
      [((now.to_time - entered_at.to_time) / 1.day).floor, 0].max if entered_at
    end
  end
end
