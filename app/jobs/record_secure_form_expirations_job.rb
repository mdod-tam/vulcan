# frozen_string_literal: true

class RecordSecureFormExpirationsJob < ApplicationJob
  queue_as :low

  def perform
    result = SecureFormExpirationRecorder.new.call

    return if result.success?

    Rails.logger.error "RecordSecureFormExpirationsJob failed: #{result.message}"
    raise StandardError, result.message
  end
end
