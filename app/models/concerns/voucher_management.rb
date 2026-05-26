# frozen_string_literal: true

# Handles all operations related to voucher management
# This includes voucher assignment, creation, and eligibility checks
module VoucherManagement
  extend ActiveSupport::Concern

  SUCCESSFUL_VOUCHER_ACTIONS = %w[voucher_assigned voucher_redeemed].freeze

  # Assigns a new voucher to this application
  # @param assigned_by [User] The user assigning the voucher (defaults to Current.user)
  # @param assignment_method [Symbol] How the voucher was assigned (:manual, :automatic, :backfill)
  # @param raise_on_failure [Boolean] Whether assignment errors should be re-raised for retryable callers
  # @return [Voucher, false] The created voucher or false on failure
  def assign_voucher!(assigned_by: nil, assignment_method: :manual, raise_on_failure: false)
    return false unless FeatureFlag.enabled?(:vouchers_enabled)

    with_lock do
      return false unless can_create_voucher?

      voucher = vouchers.create!

      # Step 1: Log the auditable business event
      AuditEventService.log(
        action: 'voucher_assigned',
        actor: assigned_by || Current.user,
        auditable: voucher, # The voucher is the auditable record
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

      # Step 2: Send the user-facing notification directly via mailer
      VoucherNotificationsMailer.with(voucher: voucher).voucher_assigned.deliver_later

      voucher
    end
  rescue StandardError => e
    Rails.logger.error "Failed to assign voucher for application #{id}: #{e.message}"
    raise if raise_on_failure

    false
  end

  # Checks if this application is eligible to receive a voucher
  # @return [Boolean] True if the application can receive a voucher
  def can_create_voucher?
    voucher_fulfillment? &&
      status_approved? &&
      required_proofs_approved? &&
      medical_certification_status_approved? &&
      voucher_missing_for_issuance?
  end

  def voucher_successfully_issued?
    vouchers.exists?(status: %i[active redeemed]) || successful_voucher_history?
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

  def voucher_missing_for_issuance?
    # One successful issue/redeem history consumes this application's voucher issuance.
    # Cancelled or expired voucher rows without that history remain eligible for legacy repair.
    !voucher_successfully_issued?
  end

  def successful_voucher_history?
    voucher_ids = Event
                  .where(action: SUCCESSFUL_VOUCHER_ACTIONS, auditable_type: 'Voucher')
                  .select(:auditable_id)

    Voucher.exists?(id: voucher_ids, application_id: id)
  end

  def create_system_notification!(recipient:, actor:, action:)
    # Use NotificationService for centralized notification creation
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
