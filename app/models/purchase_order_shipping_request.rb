# frozen_string_literal: true

class PurchaseOrderShippingRequest < ApplicationRecord
  include SecureTokenizable

  LINK_LIFETIME = 30.days
  MAIL_ACTION = 'VendorNotificationsMailer#equipment_order'

  belongs_to :purchase_order
  belongs_to :requested_by, class_name: 'User', optional: false
  has_many :email_delivery_attempts, as: :origin, dependent: :nullify

  encrypts :recipient_email, :shipping_instructions
  normalizes :recipient_email, with: ->(value) { value.to_s.strip.downcase.presence }

  enum :status, { sent: 0, submitted: 1, revoked: 2 }, prefix: true
  enum :delivery_status, { pending: 'pending', sent: 'sent', failed: 'failed' }, prefix: :delivery

  validates :recipient_email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }, length: { maximum: 254 }
  validates :shipping_instructions, length: { maximum: 2000 }, allow_blank: true
  validates :public_token_digest, :request_batch_id, :sent_at, :expires_at, presence: true

  scope :open, -> { status_sent.where(submitted_at: nil, revoked_at: nil) }
  scope :recent_first, -> { order(sent_at: :desc, id: :desc) }

  def active_for_public_use?
    super && delivery_sent? && purchase_order.direct_to_constituents? && purchase_order.sent_at.present?
  end

  def audit_subject = purchase_order
  def audit_identity = { purchase_order_shipping_request_id: id }
  def audit_metadata = audit_identity.merge(purchase_order_ids: [purchase_order_id])
  def revocation_audit_action = 'equipment_vendor_link_revoked'
  def expiration_audit_action = 'equipment_vendor_link_expired'
end
