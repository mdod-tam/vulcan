# frozen_string_literal: true

module SecureTokenizable
  extend ActiveSupport::Concern

  TOKEN_BYTES = 24

  included do
    before_validation :ensure_request_batch_id, on: :create

    # Expired, still-open links whose expiration event has not been recorded yet.
    scope :expiration_unrecorded, lambda {
      status_sent.where(submitted_at: nil, revoked_at: nil, expiration_recorded_at: nil)
                 .where(expires_at: ..Time.current)
    }
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

  # Locks the row so a submission that commits first is never overwritten.
  # Returns false, with no audit event, when the form is already submitted or revoked.
  def revoke!(actor: nil, reason: nil, metadata: {})
    revoked = false

    ApplicationRecord.transaction do
      lock!
      next if submitted? || revoked?

      revoked_time = Time.current
      update!(status: :revoked, revoked_at: revoked_time)
      record_revocation_audit_event(actor: actor, reason: reason, metadata: metadata, revoked_at: revoked_time)
      revoked = true
    end

    revoked
  end

  def display_status
    return :submitted if submitted?
    return :revoked if revoked?
    return :expired if expired?

    :active
  end

  # Each form model defines these, so a new form type cannot silently skip its audit events.
  def audit_subject = raise(NotImplementedError, "#{self.class.name} must define audit_subject")
  def audit_identity = raise(NotImplementedError, "#{self.class.name} must define audit_identity")
  def audit_metadata = raise(NotImplementedError, "#{self.class.name} must define audit_metadata")
  def revocation_audit_action = raise(NotImplementedError, "#{self.class.name} must define revocation_audit_action")
  def expiration_audit_action = raise(NotImplementedError, "#{self.class.name} must define expiration_audit_action")

  private

  def ensure_request_batch_id
    self.request_batch_id ||= SecureRandom.uuid
  end

  def record_revocation_audit_event(actor:, reason:, metadata:, revoked_at:)
    event_actor = actor || requested_by
    return if event_actor.blank?

    event_metadata = audit_metadata
    event_metadata[:reason] = reason.to_s if reason.present?

    AuditEventService.log(
      action: revocation_audit_action,
      actor: event_actor,
      auditable: audit_subject,
      created_at: revoked_at,
      metadata: event_metadata.merge(metadata.to_h)
    )
  end
end
