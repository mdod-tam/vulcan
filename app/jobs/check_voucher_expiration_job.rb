# frozen_string_literal: true

class CheckVoucherExpirationJob < ApplicationJob
  queue_as :default

  def perform
    return unless FeatureFlag.enabled?(:vouchers_enabled)

    result = Vouchers::ExpirationProcessorService.new.call

    return if result.success?

    Rails.logger.error "CheckVoucherExpirationJob failed: #{result.message}"
    raise StandardError, result.message
  end
end
