# frozen_string_literal: true

class MedicalProviderSecureRequestForm < ApplicationRecord
  include SecureTokenizable

  encrypts :provider_email, deterministic: true

  belongs_to :application
  belongs_to :requested_by, class_name: 'User', optional: true

  enum :kind, { certification_upload: 0 }, prefix: true
  enum :status, { sent: 0, submitted: 1, revoked: 2 }, prefix: true

  validates :provider_email, presence: true
  validates :request_batch_id, presence: true
  validates :public_token_digest, presence: true, uniqueness: true
  validates :expires_at, presence: true
  validates :sent_at, presence: true

  scope :certification_upload, -> { where(kind: kinds[:certification_upload]) }
  scope :active, -> { status_sent.where(submitted_at: nil, revoked_at: nil).where(arel_table[:expires_at].gt(Time.current)) }
  scope :open_certification_upload_for_provider, lambda { |application_id:, provider_email:|
    certification_upload.status_sent.where(application_id: application_id, provider_email: provider_email)
                        .where(submitted_at: nil, revoked_at: nil)
  }
end
