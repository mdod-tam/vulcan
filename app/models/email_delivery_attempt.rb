# frozen_string_literal: true

class EmailDeliveryAttempt < ApplicationRecord
  MAX_CHECKS = 8
  MAX_AGE = 7.days
  CHECK_INTERVAL = 1.hour

  encrypts :destination
  belongs_to :notification, optional: true
  belongs_to :application, optional: true
  belongs_to :origin, polymorphic: true, optional: true
  belongs_to :recipient, class_name: 'User', optional: true
  belongs_to :delivery_owner, class_name: 'User', optional: true
  belongs_to :bounce_event, class_name: 'Event', optional: true
  has_many :email_delivery_receipts, dependent: :destroy

  validates :correlation_id, :recipient_key, :destination, :server_id, :mail_action, :attempted_at, presence: true
  validates :state, inclusion: { in: %w[unknown accepted failed] }
  validates :check_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :unconfirmed, -> { where(delivered_at: nil, bounced_at: nil, complained_at: nil).where.not(state: 'failed') }
  scope :pollable, lambda {
    unconfirmed.where.not(provider_message_id: nil).where(check_count: ...MAX_CHECKS)
               .where(attempted_at: MAX_AGE.ago..)
               .where('last_checked_at IS NULL OR last_checked_at <= ?', CHECK_INTERVAL.ago)
  }

  def self.correlation_for(context)
    return unless context&.dig('request_id')

    context['delivery_correlation_id'] || Digest::SHA256.hexdigest(context['request_id'])
  end

  def self.previously_attempted?(context)
    correlation = correlation_for(context)
    correlation && exists?(correlation_id: correlation)
  end

  def self.recipient_key(address)
    OpenSSL::HMAC.hexdigest('SHA256', Rails.application.key_generator.generate_key('email-delivery-destination'), address.to_s.strip.downcase)
  end

  def confirmed?
    delivered_at.present? || bounced_at.present? || complained_at.present? || state == 'failed'
  end

  def check_available?
    provider_message_id.present? && !confirmed? && check_count < MAX_CHECKS && attempted_at >= MAX_AGE.ago &&
      (last_checked_at.nil? || last_checked_at <= CHECK_INTERVAL.ago)
  end

  def tracking_stale?
    check_failed_at.present? || check_count >= MAX_CHECKS || attempted_at < MAX_AGE.ago
  end

  def actionable_request?
    case origin
    when SecureRequestForm
      return false unless origin.active?
      return application&.missing_required_provider_info? if origin.kind_provider_info_request?

      application&.proof_requestable_via_secure_form?(origin.kind.delete_suffix('_proof_resubmission'))
    when MedicalProviderSecureRequestForm
      origin.active? && application&.medical_certification_status != 'approved'
    when VendorSecureRequestForm
      origin.active?
    when Application
      mail_action.start_with?('MedicalProviderMailer#') && application&.medical_certification_status.in?(%w[requested rejected])
    else
      false
    end
  end

  def attention?
    (bounced_at.present? || complained_at.present? || state == 'failed' || (!confirmed? && attempted_at < 24.hours.ago)) &&
      actionable_request?
  end
end
