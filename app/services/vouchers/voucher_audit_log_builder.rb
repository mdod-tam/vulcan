# frozen_string_literal: true

module Vouchers
  class VoucherAuditLogBuilder < BaseService
    attr_reader :voucher

    def initialize(voucher)
      super()
      @voucher = voucher
    end

    # Events whose metadata names this voucher's id or code, newest first.
    def build_audit_logs
      return [] unless voucher

      Event.where('metadata @> ?', { voucher_id: voucher.id }.to_json)
           .or(Event.where('metadata @> ?', { voucher_code: voucher.code }.to_json))
           .includes(:user)
           .order(created_at: :desc)
           .to_a
    rescue StandardError => e
      Rails.logger.error "Failed to build audit logs for voucher #{voucher.id}: #{e.class.name}"
      add_error("Failed to build audit logs: #{e.message}")
      []
    end

    # The same events with duplicates merged by Applications::EventDeduplicationService.
    def build_deduplicated_audit_logs
      return [] unless voucher

      events = build_audit_logs
      Applications::EventDeduplicationService.new.deduplicate(events)
    rescue StandardError => e
      Rails.logger.error "Failed to build deduplicated audit logs for voucher #{voucher.id}: #{e.class.name}"
      add_error("Failed to build deduplicated audit logs: #{e.message}")
      []
    end
  end
end
