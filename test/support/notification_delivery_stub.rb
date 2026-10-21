# frozen_string_literal: true

# This file stubs out notification delivery methods for testing

# Stub NotificationJob and NotificationRetryJob
class NotificationJob
  def self.set(*)
    self
  end

  def self.perform_later(record)
    # Do nothing in tests
  end
end

class NotificationRetryJob
  def self.set(*)
    self
  end

  def self.perform_later(record)
    # Do nothing in tests
  end
end
