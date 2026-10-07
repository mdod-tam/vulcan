# frozen_string_literal: true

module Vouchers
  class VoucherAuditLogBuilder < BaseService
    attr_reader :voucher

    def initialize(voucher)
      super()
      @voucher = voucher
    end

    # Build combined audit logs from multiple sources for a voucher
    def build_audit_logs
      return [] unless voucher

      # Currently, only events directly related to the voucher are logged in the Event model.
      # In the future, this could be expanded to include:
      # - VoucherTransaction events (e.g., redemption, refund)
      # - Invoice events related to the voucher
      # - User profile changes related to the voucher's recipient (if applicable)
      # - Application events related to the voucher's parent application

      Event.where('metadata @> ?', { voucher_id: voucher.id }.to_json)
           .or(Event.where('metadata @> ?', { voucher_code: voucher.code }.to_json))
           .includes(:user)
           .order(created_at: :desc)
           .to_a
    rescue StandardError => e
      Rails.logger.error "Failed to build audit logs for voucher #{voucher.id}: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      add_error("Failed to build audit logs: #{e.message}")
      []
    end

    # Build deduplicated audit logs using the EventDeduplicationService
    def build_deduplicated_audit_logs
      return [] unless voucher

      events = build_audit_logs
      Applications::EventDeduplicationService.new.deduplicate(events)
    rescue StandardError => e
      Rails.logger.error "Failed to build deduplicated audit logs for voucher #{voucher.id}: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      add_error("Failed to build deduplicated audit logs: #{e.message}")
      []
    end
  end
end
