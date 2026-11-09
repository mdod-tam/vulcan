# frozen_string_literal: true

class PruneContactVerificationsJob < ApplicationJob
  def perform
    cutoff = 7.days.ago
    ContactChangeRequest.where(expires_at: cutoff..).find_each { |change| change.enqueue_deliveries!(reconcile: true) }
    ContactChangeRequest.where(expires_at: ...cutoff).find_each do |change|
      change.with_lock do
        unresolved = change.delivery_states.slice('old_completed', 'new_completed').reject do |_role, state|
          state.in?(ContactChangeRequest::FINAL_DELIVERY_STATES)
        end
        if unresolved.any?
          AuditEventService.log(action: 'account_contact_notice_abandoned', actor: PublicAuditActor.system_audit_actor!,
                                auditable: change.user,
                                metadata: { operation_id: "contact-change:#{change.id}:notice-retention",
                                            contact_change_request_id: change.id, delivery_states: unresolved,
                                            reason: 'proof_payload_retention_expired' })
        end
        change.destroy!
      end
    end
    SmsVerificationAttempt.where(ownership_expires_at: ...1.day.ago).in_batches.destroy_all
  end
end
