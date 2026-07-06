# frozen_string_literal: true

# Resolves attribution for unauthenticated security/rate-limit audits.
# Never creates or promotes privileged users from public requests, and never
# substitutes a real human admin when the configured system audit actor is absent.
module PublicAuditActor
  SYSTEM_AUDIT_EMAIL = 'system@mdmat.org'
  PUBLIC_AUDIT_ACTOR_METADATA = 'public_unauthenticated'

  module_function

  def system_audit_actor
    User.admins.find_by(email: SYSTEM_AUDIT_EMAIL)
  end

  def log_audit(action:, auditable: nil, metadata: {})
    actor = system_audit_actor
    unless actor
      Rails.logger.warn(
        "PublicAuditActor: skipped audit '#{action}' — no configured system audit actor (#{SYSTEM_AUDIT_EMAIL})"
      )
      return nil
    end

    AuditEventService.log(
      action: action,
      actor: actor,
      auditable: auditable,
      metadata: metadata.reverse_merge(public_audit_actor: PUBLIC_AUDIT_ACTOR_METADATA)
    )
  rescue StandardError => e
    Rails.logger.warn("PublicAuditActor: unable to log audit '#{action}': #{e.message}")
    nil
  end
end
