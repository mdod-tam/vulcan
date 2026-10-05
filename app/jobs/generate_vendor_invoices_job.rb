# frozen_string_literal: true

# Solid Queue schedules this job through config/recurring.yml.
# Invoices::GenerationService owns invoice periods, transaction links, audit events, and vendor notices.
class GenerateVendorInvoicesJob < ApplicationJob
  queue_as :default

  def perform
    Rails.logger.info 'Starting GenerateVendorInvoicesJob'

    result = Invoices::GenerationService.new.call

    if result.failure?
      Rails.logger.error "GenerateVendorInvoicesJob failed: #{result.message}"
      raise StandardError, result.message
    end

    Rails.logger.info "GenerateVendorInvoicesJob completed: #{result.message}"
  end
end
