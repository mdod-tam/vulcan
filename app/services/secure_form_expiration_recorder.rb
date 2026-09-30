# frozen_string_literal: true

# Records one expiration event per expired, still-open secure link and marks the
# form, so each hourly run scans only forms that still need an event.
class SecureFormExpirationRecorder < BaseService
  def call
    counts = {
      proof: record_expirations(SecureRequestForm.proof_resubmission.includes(:application, :recipient, :requested_by)),
      certification: record_expirations(MedicalProviderSecureRequestForm.includes(:application, :requested_by)),
      w9: record_expirations(VendorSecureRequestForm.includes(:vendor, :requested_by))
    }

    success('Secure form expirations recorded.', counts)
  rescue StandardError => e
    log_error(e, 'Failed to record secure form expirations')
    failure('Failed to record secure form expirations.')
  end

  private

  def record_expirations(forms)
    recorded_count = 0

    forms.expiration_unrecorded.find_each do |form|
      # Forms expired before the marker existed may already have their event.
      unless expiration_event_recorded?(form)
        actor = form.requested_by || User.system_user
        next unless actor

        AuditEventService.log(
          action: form.expiration_audit_action,
          actor: actor,
          auditable: form.audit_subject,
          metadata: form.audit_metadata.merge(expires_at: form.expires_at.iso8601),
          created_at: form.expires_at
        )
        recorded_count += 1
      end
      form.update_column(:expiration_recorded_at, Time.current) # rubocop:disable Rails/SkipsModelValidations
    end

    recorded_count
  end

  def expiration_event_recorded?(form)
    Event.where(action: form.expiration_audit_action, auditable: form.audit_subject)
         .exists?(['metadata @> ?', form.audit_identity.to_json])
  end
end
