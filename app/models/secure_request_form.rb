# frozen_string_literal: true

class SecureRequestForm < ApplicationRecord
  attr_accessor :delivery_notification

  has_many :email_delivery_attempts, as: :origin, dependent: :nullify
  has_many :print_queue_items, dependent: :restrict_with_error
  include SecureTokenizable

  DELIVERY_SOURCES = %w[constituent dependent_contact managing_guardian guardian_relationship].freeze

  encrypts :recipient_email, deterministic: true
  encrypts :recipient_phone, deterministic: true

  def delivery_locale
    SecureFormLocaleResolver.normalize(delivery_owner ? delivery_owner.locale : recipient&.effective_message_locale)
  end

  belongs_to :application
  belongs_to :recipient, class_name: 'User'
  belongs_to :requested_by, class_name: 'User', optional: true
  # Owns the selected contact or postal address. A guardian can own a dependent's delivery.
  belongs_to :delivery_owner, class_name: 'User', optional: true

  # Public endpoints and services use kind_provider_info_request? to prevent
  # proof-resubmission tokens from accessing provider-info forms.
  enum :kind, {
    provider_info_request: 0,
    id_proof_resubmission: 1,
    residency_proof_resubmission: 2,
    income_proof_resubmission: 3
  }, prefix: true
  enum :status, { sent: 0, submitted: 1, revoked: 2 }, prefix: true
  enum :recipient_channel, { email: 0, sms: 1, letter: 2 }, prefix: true
  enum :recipient_role, { constituent: 0, guardian: 1 }, prefix: true

  validates :request_batch_id, presence: true
  validates :delivery_owner, :delivery_source, presence: true, on: :create
  validates :delivery_source,
            inclusion: { in: DELIVERY_SOURCES },
            allow_nil: true
  validate :delivery_provenance_is_complete
  validates :recipient_channel, presence: true
  validates :recipient_role, presence: true
  validates :public_token_digest, presence: true, uniqueness: true
  validates :expires_at, presence: true
  validates :sent_at, presence: true

  scope :provider_info, -> { where(kind: kinds[:provider_info_request]) }
  scope :proof_resubmission, lambda {
    where(kind: [
            kinds[:id_proof_resubmission],
            kinds[:residency_proof_resubmission],
            kinds[:income_proof_resubmission]
          ])
  }
  scope :id_proof, -> { where(kind: kinds[:id_proof_resubmission]) }
  scope :residency_proof, -> { where(kind: kinds[:residency_proof_resubmission]) }
  scope :income_proof, -> { where(kind: kinds[:income_proof_resubmission]) }
  scope :active, -> { status_sent.where(submitted_at: nil, revoked_at: nil).where(arel_table[:expires_at].gt(Time.current)) }
  scope :with_incomplete_delivery_provenance, lambda {
    where(delivery_owner_id: nil).or(where(delivery_source: nil))
  }
  # The open_*_for_recipient scopes also require nil timestamps, because status
  # and timestamps can disagree (see revoked? and submitted?).
  scope :open_provider_info_for_recipient, lambda { |application_id:, recipient_id:|
    provider_info.status_sent.where(application_id: application_id, recipient_id: recipient_id)
                 .where(submitted_at: nil, revoked_at: nil)
  }
  scope :open_id_proof_for_recipient, lambda { |application_id:, recipient_id:|
    id_proof.status_sent.where(application_id: application_id, recipient_id: recipient_id)
            .where(submitted_at: nil, revoked_at: nil)
  }
  scope :open_residency_proof_for_recipient, lambda { |application_id:, recipient_id:|
    residency_proof.status_sent.where(application_id: application_id, recipient_id: recipient_id)
                   .where(submitted_at: nil, revoked_at: nil)
  }
  scope :open_income_proof_for_recipient, lambda { |application_id:, recipient_id:|
    income_proof.status_sent.where(application_id: application_id, recipient_id: recipient_id)
                .where(submitted_at: nil, revoked_at: nil)
  }

  def delivery_provenance?
    delivery_owner_id.present? && delivery_source.present?
  end

  PROOF_TYPES_BY_KIND = {
    'id_proof_resubmission' => 'id',
    'residency_proof_resubmission' => 'residency',
    'income_proof_resubmission' => 'income'
  }.freeze

  def audit_subject = application
  def audit_identity = { secure_request_form_id: id }

  def audit_metadata
    {
      application_id: application_id,
      **audit_identity,
      request_batch_id: request_batch_id,
      recipient_id: recipient_id,
      recipient_name: recipient&.full_name,
      recipient_role: recipient_role,
      recipient_channel: recipient_channel,
      kind: kind,
      proof_type: PROOF_TYPES_BY_KIND[kind]
    }
  end

  def revocation_audit_action
    kind_provider_info_request? ? 'provider_info_request_revoked' : 'proof_resubmission_request_revoked'
  end

  # Only proof links record an expiration event.
  def expiration_audit_action
    'proof_resubmission_request_expired' unless kind_provider_info_request?
  end

  private

  def delivery_provenance_is_complete
    return if delivery_owner_id.present? == delivery_source.present?

    errors.add(:base, 'Delivery owner and delivery source must both be present or both be absent')
  end
end
