# frozen_string_literal: true

module Vouchers
  # Issues an application's voucher with its audit event and assignment notice. The result's data[:voucher] is the
  # new voucher.
  class IssuanceService < BaseService
    # @param application [Application] The application to issue the voucher for
    # @param actor [User] The user the audit event names
    # @param assignment_method [Symbol] How the voucher was assigned (:manual, :manual_approval, :automatic)
    # @param raise_on_failure [Boolean] Whether an error is re-raised for a retrying caller instead of returning a failure
    def initialize(application, actor:, assignment_method: :manual, raise_on_failure: false)
      super()
      @application = application
      @actor = actor
      @assignment_method = assignment_method
      @raise_on_failure = raise_on_failure
    end

    def call
      return failure('Vouchers are not enabled') unless FeatureFlag.enabled?(:vouchers_enabled)

      @application.with_lock do
        return failure('Application is not eligible for a voucher') unless @application.can_create_voucher?

        voucher = @application.vouchers.create!
        log_assignment(voucher)
        VoucherNotificationsMailer.with(voucher: voucher).voucher_assigned.deliver_later
        success(nil, voucher: voucher)
      end
    rescue StandardError => e
      Rails.logger.error "Failed to assign voucher for application #{@application.id}: #{e.class.name}"
      raise if @raise_on_failure

      failure('Voucher could not be issued')
    end

    private

    def log_assignment(voucher)
      AuditEventService.log(
        action: 'voucher_assigned',
        actor: @actor,
        auditable: voucher,
        metadata: {
          application_id: @application.id,
          voucher_id: voucher.id,
          voucher_code: voucher.code,
          initial_value: voucher.initial_value,
          issued_at: voucher.issued_at.iso8601,
          assignment_method: @assignment_method.to_s,
          timestamp: Time.current.iso8601
        }
      )
    end
  end
end
