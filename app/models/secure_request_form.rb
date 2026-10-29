# frozen_string_literal: true

class SecureRequestForm < ApplicationRecord
  attr_accessor :delivery_notification

  has_many :email_delivery_attempts, as: :origin, dependent: :nullify
  has_many :print_queue_items, dependent: :restrict_with_error
  include SecureTokenizable

  DELIVERY_SOURCES = %w[constituent dependent_contact managing_guardian guardian_relationship].freeze

  encrypts :recipient_email, deterministic: true
  encrypts :recipient_phone, deterministic: true

  # A provider gets the default locale: the constituent's locale says nothing about the provider's language.
  def delivery_locale
    return I18n.default_locale if kind_certification_upload?

    SecureFormLocaleResolver.normalize(delivery_owner ? delivery_owner.locale : recipient&.effective_message_locale)
  end

  belongs_to :application
  # The certifying provider is not a user, so a certification link has no recipient.
  belongs_to :recipient, class_name: 'User', optional: true
  belongs_to :requested_by, class_name: 'User', optional: true
  # Owns the selected contact or postal address. A guardian can own a dependent's delivery.
  belongs_to :delivery_owner, class_name: 'User', optional: true

  # Public endpoints and services check the kind so a token for one kind cannot open another kind's page.
  # The certification pages resolve tokens only through the certification_upload scope.
  enum :kind, {
    provider_info_request: 0,
    id_proof_resubmission: 1,
    residency_proof_resubmission: 2,
    income_proof_resubmission: 3,
    certification_upload: 4
  }, prefix: true
  enum :status, { sent: 0, submitted: 1, revoked: 2 }, prefix: true
  enum :recipient_channel, { email: 0, sms: 1, letter: 2 }, prefix: true
  enum :recipient_role, { constituent: 0, guardian: 1, provider: 2 }, prefix: true

  validates :request_batch_id, presence: true
  validates :recipient, presence: { message: :required }, unless: :kind_certification_upload?
  validates :delivery_owner, :delivery_source, presence: true, on: :create, unless: :kind_certification_upload?
  validate :certification_upload_is_addressed_to_a_provider, if: :kind_certification_upload?
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
  scope :certification_upload, -> { where(kind: kinds[:certification_upload]) }
  # Everything except certification links, which have no user recipient or delivery owner.
  scope :for_user_recipients, -> { where.not(kind: kinds[:certification_upload]) }
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
    for_user_recipients.where(delivery_owner_id: nil).or(for_user_recipients.where(delivery_source: nil))
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
  # An application has one certifying provider, so a new request replaces every open one.
  scope :open_certification_upload_for_application, lambda { |application_id:|
    certification_upload.status_sent.where(application_id: application_id).where(submitted_at: nil, revoked_at: nil)
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
    return certification_upload_audit_metadata if kind_certification_upload?

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
    case kind
    when 'certification_upload' then 'cert_upload_request_revoked'
    when 'provider_info_request' then 'provider_info_request_revoked'
    else 'proof_resubmission_request_revoked'
    end
  end

  # Provider-info links record no expiration event.
  def expiration_audit_action
    case kind
    when 'certification_upload' then 'cert_upload_request_expired'
    when 'provider_info_request' then nil
    else 'proof_resubmission_request_expired'
    end
  end

  private

  # recipient_name and recipient_email hold the provider's, not a user's.
  def certification_upload_audit_metadata
    {
      application_id: application_id,
      **audit_identity,
      request_batch_id: request_batch_id,
      provider_name: recipient_name,
      provider_email: recipient_email,
      requested_channel: 'email'
    }
  end

  # The database CHECK holds the same rule; this gives the issuer a readable error first.
  def certification_upload_is_addressed_to_a_provider
    errors.add(:recipient_email, :blank) if recipient_email.blank?
    errors.add(:base, 'A certification link has no user recipient or delivery owner') if recipient_id || delivery_owner_id || delivery_source
    errors.add(:recipient_role, :inclusion) unless recipient_role_provider?
    errors.add(:recipient_channel, :inclusion) unless recipient_channel_email?
  end

  def delivery_provenance_is_complete
    return if delivery_owner_id.present? == delivery_source.present?

    errors.add(:base, 'Delivery owner and delivery source must both be present or both be absent')
  end
end
