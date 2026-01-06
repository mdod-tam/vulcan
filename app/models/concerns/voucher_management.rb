# frozen_string_literal: true

# Handles all operations related to voucher management
# This includes voucher assignment, creation, and eligibility checks
module VoucherManagement
  extend ActiveSupport::Concern

  # Assigns a new voucher to this application
  # @param assigned_by [User] The user assigning the voucher (defaults to Current.user)
  # @return [Voucher, false] The created voucher or false on failure
  def assign_voucher!(assigned_by: nil)
    return false unless can_create_voucher?
    return false unless FeatureFlag.enabled?(:voucher_enabled)

    with_lock do
      voucher = vouchers.create!

      # Step 1: Log the auditable business event
      AuditEventService.log(
        action: 'voucher_assigned',
        actor: assigned_by || Current.user,
        auditable: voucher, # The voucher is the auditable record
        metadata: {
          application_id: id,
          voucher_code: voucher.code,
          initial_value: voucher.initial_value,
          timestamp: Time.current.iso8601
        }
      )

      # Step 2: Send the user-facing notification directly via mailer
      VoucherNotificationsMailer.with(voucher: voucher).voucher_assigned.deliver_later

      voucher
    end
  rescue StandardError => e
    Rails.logger.error "Failed to assign voucher for application #{id}: #{e.message}"
    false
  end

  # Checks if this application is eligible to receive a voucher
  # @return [Boolean] True if the application can receive a voucher
  def can_create_voucher?
    status_approved? &&
      medical_certification_status_approved? &&
      !vouchers.exists?
  end

  # Creates an initial voucher for a newly approved application
  # @return [Voucher, nil] The created voucher or nil if not eligible
  def create_initial_voucher
    return unless can_create_voucher?

    assign_voucher!(assigned_by: Current.user)
  end

  private

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
