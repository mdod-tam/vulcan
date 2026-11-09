# frozen_string_literal: true

class PruneRegistrationVerificationsJob < ApplicationJob
  def perform
    RegistrationVerification.where(expires_at: ...1.day.ago).find_each(&:destroy!)
    AuthRateLimitCounter.where(expires_at: ...1.day.ago).delete_all
  end
end
