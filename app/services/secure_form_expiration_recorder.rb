# frozen_string_literal: true

class SecureFormExpirationRecorder < BaseService
  EXPIRATION_ACTIONS = {
    proof: 'proof_resubmission_request_expired',
    certification: 'cert_upload_request_expired',
    w9: 'w9_upload_request_expired'
  }.freeze

  PROOF_TYPES_BY_KIND = {
    'id_proof_resubmission' => 'id',
    'residency_proof_resubmission' => 'residency',
    'income_proof_resubmission' => 'income'
  }.freeze

  def call
    counts = {
      proof: record_proof_expirations,
      certification: record_certification_expirations,
      w9: record_w9_expirations
    }

    success('Secure form expirations recorded.', counts)
  rescue StandardError => e
    log_error(e, 'Failed to record secure form expirations')
    failure('Failed to record secure form expirations.')
  end

  private

  def record_proof_expirations
    record_expirations(expired_open_proof_forms, EXPIRATION_ACTIONS.fetch(:proof)) do |form|
      {
        application_id: form.application_id,
        secure_request_form_id: form.id,
        request_batch_id: form.request_batch_id,
        recipient_id: form.recipient_id,
        recipient_name: form.recipient&.full_name,
        recipient_role: form.recipient_role,
        recipient_channel: form.recipient_channel,
        kind: form.kind,
        proof_type: proof_type_for(form),
        expires_at: form.expires_at.iso8601
      }
    end
  end

  def record_certification_expirations
    record_expirations(expired_open_certification_forms, EXPIRATION_ACTIONS.fetch(:certification)) do |form|
      {
        application_id: form.application_id,
        medical_provider_secure_request_form_id: form.id,
        request_batch_id: form.request_batch_id,
        provider_name: form.provider_name,
        provider_email: form.provider_email,
        requested_channel: 'email',
        expires_at: form.expires_at.iso8601
      }
    end
  end

  def record_w9_expirations
    record_expirations(expired_open_w9_forms, EXPIRATION_ACTIONS.fetch(:w9)) do |form|
      {
        vendor_secure_request_form_id: form.id,
        vendor_id: form.vendor_id,
        request_batch_id: form.request_batch_id,
        recipient_email: form.recipient_email,
        kind: form.kind,
        requested_channel: 'email',
        expires_at: form.expires_at.iso8601
      }
    end
  end

  def record_expirations(forms, action)
    recorded_count = 0

    forms.find_each do |form|
      next if expiration_event_recorded?(form, action)

      AuditEventService.log(
        action: action,
        actor: expiration_actor_for(form),
        auditable: auditable_for(form),
        metadata: yield(form),
        created_at: form.expires_at
      )
      recorded_count += 1
    end

    recorded_count
  end

  def expiration_actor_for(form)
    form.requested_by || User.system_user
  end

  def expired_open_proof_forms
    SecureRequestForm
      .proof_resubmission
      .status_sent
      .where(submitted_at: nil, revoked_at: nil)
      .where(expires_at: ..Time.current)
      .includes(:application, :recipient, :requested_by)
  end

  def expired_open_certification_forms
    MedicalProviderSecureRequestForm
      .status_sent
      .where(submitted_at: nil, revoked_at: nil)
      .where(expires_at: ..Time.current)
      .includes(:application, :requested_by)
  end

  def expired_open_w9_forms
    VendorSecureRequestForm
      .status_sent
      .where(submitted_at: nil, revoked_at: nil)
      .where(expires_at: ..Time.current)
      .includes(:vendor, :requested_by)
  end

  def expiration_event_recorded?(form, action)
    Event
      .where(action: action, auditable: auditable_for(form))
      .exists?(['metadata @> ?', expiration_event_identity(form).to_json])
  end

  def expiration_event_identity(form)
    case form
    when SecureRequestForm
      { secure_request_form_id: form.id }
    when MedicalProviderSecureRequestForm
      { medical_provider_secure_request_form_id: form.id }
    when VendorSecureRequestForm
      { vendor_secure_request_form_id: form.id }
    end
  end

  def auditable_for(form)
    return form.vendor if form.is_a?(VendorSecureRequestForm)

    form.application
  end

  def proof_type_for(form)
    PROOF_TYPES_BY_KIND[form.kind]
  end
end
