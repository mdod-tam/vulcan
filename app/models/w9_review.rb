# frozen_string_literal: true

class W9Review < ApplicationRecord
  # Associations
  belongs_to :vendor, class_name: 'User'
  belongs_to :reviewed_blob, class_name: 'ActiveStorage::Blob', optional: true
  attr_readonly :reviewed_blob_id
  validates :reviewed_blob, presence: true, on: :create
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
