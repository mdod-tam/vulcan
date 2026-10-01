# frozen_string_literal: true

class VendorSecureRequestForm < ApplicationRecord
  attr_accessor :delivery_notification

  has_many :email_delivery_attempts, as: :origin, dependent: :nullify
  include SecureTokenizable

  encrypts :recipient_email, deterministic: true

  belongs_to :vendor, class_name: 'User'
  belongs_to :requested_by, class_name: 'User', optional: true

  enum :kind, { w9_upload: 0 }, prefix: true

  def delivery_locale
    SecureFormLocaleResolver.for_recipient(vendor)
  end
  enum :status, { sent: 0, submitted: 1, revoked: 2 }, prefix: true

  validates :recipient_email, presence: true
  validates :request_batch_id, presence: true
  validates :public_token_digest, presence: true, uniqueness: true
  validates :expires_at, presence: true
  validates :sent_at, presence: true

  scope :w9_upload, -> { where(kind: kinds[:w9_upload]) }
  scope :active, -> { status_sent.where(submitted_at: nil, revoked_at: nil).where(arel_table[:expires_at].gt(Time.current)) }
  scope :open_w9_upload_for_vendor, lambda { |vendor_id:|
    w9_upload.status_sent.where(vendor_id: vendor_id)
             .where(submitted_at: nil, revoked_at: nil)
  }

  def audit_subject = vendor
  def audit_identity = { vendor_secure_request_form_id: id }
  def revocation_audit_action = 'w9_upload_request_revoked'
  def expiration_audit_action = 'w9_upload_request_expired'

  def audit_metadata
    {
      **audit_identity,
      vendor_id: vendor_id,
      request_batch_id: request_batch_id,
      recipient_email: recipient_email,
      kind: kind,
      requested_channel: 'email'
    }
  end
end
