# frozen_string_literal: true

# Voucher assignment and eligibility for an application.
module VoucherManagement
  extend ActiveSupport::Concern

  # Assigns a new voucher to this application
  # @param assigned_by [User] The user assigning the voucher (defaults to Current.user)
  # @param assignment_method [Symbol] How the voucher was assigned (:manual, :manual_approval, :automatic)
  # @param raise_on_failure [Boolean] Whether assignment errors should be re-raised for retryable callers
  # @return [Voucher, false] The created voucher or false on failure
  def assign_voucher!(assigned_by: nil, assignment_method: :manual, raise_on_failure: false)
    return false unless FeatureFlag.enabled?(:vouchers_enabled)

    with_lock do
      return false unless can_create_voucher?

      voucher = vouchers.create!

      AuditEventService.log(
        action: 'voucher_assigned',
        actor: assigned_by || Current.user,
        auditable: voucher,
        metadata: {
          application_id: id,
          voucher_id: voucher.id,
          voucher_code: voucher.code,
          initial_value: voucher.initial_value,
          issued_at: voucher.issued_at.iso8601,
          assignment_method: assignment_method.to_s,
          timestamp: Time.current.iso8601
        }
      )

      VoucherNotificationsMailer.with(voucher: voucher).voucher_assigned.deliver_later

      voucher
    end
  rescue StandardError => e
    Rails.logger.error "Failed to assign voucher for application #{id}: #{e.class.name}"
    raise if raise_on_failure

    false
  end

  # Checks if this application is eligible to receive a voucher
  # @return [Boolean] True if the application can receive a voucher
  def can_create_voucher?
    voucher_fulfillment? &&
      status_approved? &&
      required_proofs_approved? &&
      disability_certification_status_approved? &&
      !vouchers.exists?
  end

  def maybe_assign_initial_voucher!(actor:, assignment_method: :automatic)
    return unless FeatureFlag.enabled?(:vouchers_enabled)
    return unless can_create_voucher?

    assign_voucher!(
      assigned_by: actor,
      assignment_method: assignment_method,
      raise_on_failure: true
    )
  end

  private

  def create_system_notification!(recipient:, actor:, action:)
    NotificationService.create_and_deliver!(
      type: action,
      recipient: recipient,
      actor: actor,
      notifiable: self,
      metadata: {
        application_id: id
      },
      channel: :email
    )
  end
end
