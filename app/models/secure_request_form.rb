# frozen_string_literal: true

class SecureRequestForm < ApplicationRecord
  include SecureTokenizable

  encrypts :recipient_email, deterministic: true
  encrypts :recipient_phone, deterministic: true

  def delivery_locale
    locale = delivery_owner ? delivery_owner.locale : recipient&.effective_message_locale
    candidate = locale.to_s.to_sym
    I18n.available_locales.include?(candidate) ? candidate : I18n.default_locale
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
  validates :delivery_source,
            inclusion: { in: Applications::SecureRequestRecipientResolver::CONTACT_SOURCES.map(&:to_s) },
            allow_nil: true
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
  # Timestamp checks are defensive against status/timestamp drift (see revoked?/submitted?).
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
end
