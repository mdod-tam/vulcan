# frozen_string_literal: true

module SecureTokenizable
  extend ActiveSupport::Concern

  TOKEN_BYTES = 24

  included do
    before_validation :ensure_request_batch_id, on: :create
  end

  class_methods do
    def generate_public_token
      SecureRandom.urlsafe_base64(SecureTokenizable::TOKEN_BYTES)
    end

    def digest_public_token(raw_token)
      Digest::SHA256.hexdigest(raw_token.to_s)
    end

    def from_public_token(raw_token)
      return nil if raw_token.blank?

      # A normal indexed digest lookup is safe for 192-bit random bearer tokens;
      # there is no attacker-exploitable timing signal here requiring constant-time comparison.
      find_by(public_token_digest: digest_public_token(raw_token))
    end
  end

  def expired?
    expires_at.present? && expires_at <= Time.current
  end

  def active_for_public_use?
    status_sent? && revoked_at.blank? && submitted_at.blank? && !expired?
  end

  # Lifecycle predicate for admin/table actions; public submit access uses the
  # more explicit active_for_public_use? name at security-sensitive call sites.
  def active?
    active_for_public_use?
  end

  # Status and timestamp checks intentionally tolerate legacy/manual lifecycle drift.
  def revoked?
    status_revoked? || revoked_at.present?
  end

  def submitted?
    status_submitted? || submitted_at.present?
  end

  def mark_submitted!
    update!(status: :submitted, submitted_at: Time.current)
  end

  def revoke!(actor: nil, reason: nil, metadata: {})
    revoked_time = Time.current

    ApplicationRecord.transaction do
      update!(status: :revoked, revoked_at: revoked_time)
      record_revocation_audit_event(actor: actor, reason: reason, metadata: metadata, revoked_at: revoked_time)
    end
  end

  def display_status
    return :submitted if submitted?
    return :revoked if revoked?
    return :expired if expired?

    :active
  end

  private

  def ensure_request_batch_id
    self.request_batch_id ||= SecureRandom.uuid
  end

  def record_revocation_audit_event(actor:, reason:, metadata:, revoked_at:)
    auditable = secure_request_revocation_auditable
    action = secure_request_revocation_action
    event_actor = actor || secure_request_revocation_fallback_actor
    return if auditable.blank? || action.blank? || event_actor.blank?

    AuditEventService.log(
      action: action,
      actor: event_actor,
      auditable: auditable,
      created_at: revoked_at,
      metadata: secure_request_revocation_metadata(reason: reason, metadata: metadata)
    )
  end

  def secure_request_revocation_auditable
    return application if respond_to?(:application)

    vendor if respond_to?(:vendor)
  end

  def secure_request_revocation_fallback_actor
    requested_by if respond_to?(:requested_by)
  end

  def secure_request_revocation_action
    case self
    when SecureRequestForm
      if kind_provider_info_request?
        'provider_info_request_revoked'
      elsif kind_id_proof_resubmission? || kind_residency_proof_resubmission? || kind_income_proof_resubmission?
        'proof_resubmission_request_revoked'
      end
    when MedicalProviderSecureRequestForm
      'cert_upload_request_revoked' if kind_certification_upload?
    when VendorSecureRequestForm
      'w9_upload_request_revoked' if kind_w9_upload?
    end
  end

  def secure_request_revocation_metadata(reason:, metadata:)
    base_metadata = case self
                    when SecureRequestForm
                      {
                        application_id: application_id,
                        secure_request_form_id: id,
                        request_batch_id: request_batch_id,
                        recipient_id: recipient_id,
                        recipient_name: recipient&.full_name,
                        recipient_role: recipient_role,
                        recipient_channel: recipient_channel,
                        kind: kind,
                        proof_type: secure_request_form_proof_type
                      }
                    when MedicalProviderSecureRequestForm
                      {
                        application_id: application_id,
                        medical_provider_secure_request_form_id: id,
                        request_batch_id: request_batch_id,
                        provider_name: provider_name,
                        provider_email: provider_email,
                        requested_channel: 'email'
                      }
                    when VendorSecureRequestForm
                      {
                        vendor_secure_request_form_id: id,
                        vendor_id: vendor_id,
                        request_batch_id: request_batch_id,
                        recipient_email: recipient_email,
                        kind: kind,
                        requested_channel: 'email'
                      }
                    else
                      {}
                    end

    base_metadata[:reason] = reason.to_s if reason.present?
    base_metadata.merge(metadata.to_h)
  end

  def secure_request_form_proof_type
    case kind.to_s
    when 'id_proof_resubmission'
      'id'
    when 'residency_proof_resubmission'
      'residency'
    when 'income_proof_resubmission'
      'income'
    end
  end
end
