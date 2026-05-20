# frozen_string_literal: true

class W9Review < ApplicationRecord
  # Associations
  belongs_to :vendor, class_name: 'User'
  belongs_to :admin, -> { where(type: 'Users::Administrator') }, class_name: 'User'

  # Enums
  enum :status, { approved: 0, rejected: 1 }, prefix: true
  enum :rejection_reason_code, {
    address_mismatch: 0,
    tax_id_mismatch: 1,
    other: 2
  }, prefix: true

  # Validations
  validates :status, presence: true
  validates :reviewed_at, presence: true
  validates :rejection_reason, presence: true, if: -> { status_rejected? }
  validates :rejection_reason_code, presence: true, if: -> { status_rejected? }
  validate :vendor_must_be_vendor_type
  validate :validate_rejection_fields
  validate :admin_must_be_admin_type

  # Callbacks
  before_validation :set_reviewed_at, on: :create
  after_commit :handle_post_review_actions, on: :create

  # Scopes
  scope :recent, -> { order(created_at: :desc) }
  scope :by_admin, ->(admin_id) { where(admin_id: admin_id) }
  scope :rejections, -> { where(status: :rejected) }
  scope :last_3_days, -> { where('created_at > ?', 3.days.ago) }

  private

  def set_reviewed_at
    self.reviewed_at ||= Time.current
  end

  def vendor_must_be_vendor_type
    # Check that vendor exists and is actually a vendor type (either Users::Vendor or Vendor)
    return if vendor.nil? # Let the presence validation handle nil vendors

    # Check for vendor type using the STI type handling methods
    errors.add(:vendor, 'must be a vendor') unless vendor.vendor? || vendor.is_a?(Users::Vendor) || vendor.is_a?(Vendor)
  end

  def handle_post_review_actions
    return if status.blank?

    begin
      process_review_transaction
      send_review_notification
      request_secure_w9_resubmission if status_rejected?
    rescue StandardError => e
      Rails.logger.error "Failed to process W9 review actions: #{e.message}\n#{e.backtrace.join("\n")}"
      raise
    end
  end

  def process_review_transaction
    ActiveRecord::Base.transaction do
      if status_rejected?
        process_rejected_status
      else
        process_approved_status
      end
    end
  end

  def process_rejected_status
    increment_rejections_if_rejected
    check_max_rejections
    update_vendor_status(:rejected)
  end

  def process_approved_status
    update_vendor_status(:approved)
  end

  def send_review_notification
    if status_rejected?
      create_rejection_audit_notification
    else
      send_notification('w9_approved')
    end
  end

  def update_vendor_status(new_status)
    vendor.update_column(:w9_status, Users::Vendor.w9_statuses[new_status])
  rescue StandardError => e
    Rails.logger.error "Failed to update vendor status: #{e.message}"
    raise
  end

  def send_notification(action)
    metadata = if action == 'w9_rejected'
                 {
                   w9_review_id: id,
                   rejection_reason: rejection_reason,
                   rejection_reason_code: rejection_reason_code,
                   timestamp: Time.current.iso8601
                 }
               else
                 {
                   w9_review_id: id,
                   timestamp: Time.current.iso8601
                 }
               end

    # Log the audit event first
    AuditEventService.log(
      action: action,
      actor: admin,
      auditable: vendor,
      metadata: metadata
    )

    # Then, send the notification without the audit flag
    NotificationService.create_and_deliver!(
      type: action,
      recipient: vendor,
      actor: admin,
      notifiable: vendor, # W9 review is about the vendor
      metadata: metadata,
      channel: :email
    )
  rescue StandardError => e
    Rails.logger.error "Failed to send #{action} notification via NotificationService: #{e.message}"
    # Don't re-raise - notification errors shouldn't fail the whole W9 review process
  end

  def create_rejection_audit_notification
    metadata = {
      w9_review_id: id,
      rejection_reason: rejection_reason,
      rejection_reason_code: rejection_reason_code,
      timestamp: Time.current.iso8601
    }

    NotificationService.create_and_deliver!(
      type: 'w9_rejected',
      recipient: vendor,
      actor: admin,
      notifiable: vendor,
      metadata: metadata,
      channel: :email,
      audit: true,
      deliver: false
    )
  rescue StandardError => e
    Rails.logger.error "Failed to send w9_rejected notification: #{e.message}"
  end

  def request_secure_w9_resubmission
    result = Vendors::RequestW9Resubmission.new(vendor: vendor, actor: admin).call
    return if result.success?

    Rails.logger.warn(
      "W9 secure resubmission request failed for vendor #{vendor.id}: #{result.message}"
    )
  rescue StandardError => e
    Rails.logger.error "Failed to request secure W9 resubmission: #{e.message}"
  end

  def increment_rejections_if_rejected
    vendor.with_lock do
      vendor.increment!(:w9_rejections_count)
    end
  rescue StandardError => e
    errors.add(:base, "Failed to update rejection count. Please try again. Status: #{e.message}")
    raise ActiveRecord::Rollback
  end

  def check_max_rejections
    vendor.with_lock do
      if vendor.w9_rejections_count >= 8
        # Log the audit event first
        AuditEventService.log(
          action: 'vendor_max_w9_rejections_warning',
          actor: admin,
          auditable: vendor,
          metadata: { recipient_id: User.admins.first.id }
        )

        # Then, send the notification without the audit flag
        NotificationService.create_and_deliver!(
          type: 'vendor_max_w9_rejections_warning',
          recipient: User.admins.first,
          actor: admin,
          notifiable: vendor,
          channel: :email
        )
      end
    end
  rescue StandardError => e
    Rails.logger.error "Failed to process max rejections: #{e.message}"
    errors.add(:base, 'Failed to process rejection limits')
    raise ActiveRecord::Rollback
  end

  def validate_rejection_fields
    if status_rejected?
      errors.add(:rejection_reason, 'must be provided when rejecting a W9') if rejection_reason.blank?

      errors.add(:rejection_reason_code, 'must be selected when rejecting a W9') if rejection_reason_code.blank?
    else
      # Clear rejection fields if status is not rejected
      self.rejection_reason = nil
      self.rejection_reason_code = nil
    end
  end

  def admin_must_be_admin_type
    errors.add(:admin, 'must be an administrator') unless admin&.admin?
  end
end
