# frozen_string_literal: true

class AuditEventService < BaseService
  # This window suppresses matching stored events. EventDeduplicationService deduplicates events for display.
  DEDUP_WINDOW = 5.seconds
  SENSITIVE_CHANGE_FIELDS = %w[serial_duplicate_reason].freeze
  MUTATION_ACTIONS = %w[profile_updated profile_updated_by_guardian profile_updated_by_admin
                        profile_created_by_admin_via_paper alternate_contact_updated certifying_professional_info_updated
                        constituent_contact_updated vendor_updated voucher_updated].freeze

  # Logs an event, or returns nil when deduplication suppresses a matching event within DEDUP_WINDOW.
  #
  # @param action [String] The action (e.g., 'proof_approved').
  # @param actor [User] The user who performs the action.
  # @param auditable [ApplicationRecord, nil] The primary record for the action (optional).
  # @param metadata [Hash] Additional context for the event.
  # @param created_at [Time] The optional timestamp for tests.
  # @return [Event, nil] The new event, or nil if deduplication suppresses it.
  def self.log(action:, actor:, auditable: nil, metadata: {}, created_at: nil)
    # No unique index covers (action, auditable_type, auditable_id), so two concurrent identical events can both pass the check below.

    metadata = AuditMetadataPrivacy.new(auditable: auditable).filter(metadata)

    if deduplication_required?(action, auditable, metadata) && recent_duplicate_exists?(action: action, auditable: auditable, metadata: metadata)
      Rails.logger.info "AuditEventService: Duplicate event '#{action}' for #{auditable.class.name} ##{auditable.id} suppressed."
      return nil
    end

    metadata, change_values = split_device_change_values(auditable, metadata)

    # Caller metadata takes precedence over service metadata. Internal keys use a separate namespace.
    final_metadata = metadata.reverse_merge(
      __service_generated: true
    )

    event_attributes = {
      user: actor,
      action: action.to_s,
      auditable: auditable,
      metadata: final_metadata
    }
    event_attributes[:change_values] = change_values.to_json if change_values

    event_attributes[:created_at] = created_at if created_at.present?

    application_creation = action.to_s == 'application_created' && auditable.present?
    Rails.logger.debug { "AuditEventService: Creating application_created event for application #{auditable.id}" } if application_creation

    event = Event.create!(event_attributes)

    Rails.logger.debug { "AuditEventService: Successfully created event #{event.id} for application #{auditable.id}" } if application_creation

    event
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.error "AuditEventService: Failed to log event (#{e.class}) for #{auditable&.class&.name} ##{auditable&.id}"
    raise # Expose invalid events to callers and tests.
  end

  def self.deduplication_required?(action, auditable, metadata)
    return false if auditable.blank? || action.to_s == 'application_created'
    return true if metadata['operation_id'].present? || metadata[:operation_id].present?

    MUTATION_ACTIONS.exclude?(action.to_s)
  end
  private_class_method :deduplication_required?

  # Personal masks stay in metadata; only device-history values need encrypted storage.
  def self.split_device_change_values(auditable, metadata)
    key = metadata.key?(:changes) ? :changes : 'changes'
    changes = metadata[key]
    encrypted = Array(auditable.class.try(:encrypted_attributes)).map(&:to_s) + SENSITIVE_CHANGE_FIELDS
    encrypted &= AuditMetadataPrivacy::ENCRYPTED_DEVICE_FIELDS
    return [metadata, nil] unless changes.is_a?(Hash)

    values = changes.select { |field, _change| encrypted.include?(field.to_s) }
    return [metadata, nil] if values.empty?

    masked = changes.to_h { |field, change| [field, values.key?(field) ? {} : change] }
    [metadata.merge(key => masked), values.deep_stringify_keys]
  end

  # Matches action, auditable, and fingerprint within DEDUP_WINDOW.
  # Metadata differences can identify separate events.
  def self.recent_duplicate_exists?(action:, auditable:, metadata: {})
    return false if auditable.nil?

    fingerprint = create_event_fingerprint(action, metadata)

    Event.where(action: action.to_s, auditable: auditable)
         .where(created_at: DEDUP_WINDOW.ago..)
         .any? { |event| create_event_fingerprint(event.action, event.metadata) == fingerprint }
  end

  # These fingerprints select the metadata that affects deduplication.
  def self.create_event_fingerprint(action, metadata) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    base = action.to_s

    # Different operation IDs retain separate audit events within DEDUP_WINDOW.
    # A retry with the same ID uses the same fingerprint.
    operation_id = metadata['operation_id'] || metadata[:operation_id]
    return "#{base}_operation_#{operation_id}" if operation_id.present?

    reviewed_blob_id = metadata['reviewed_blob_id'] || metadata[:reviewed_blob_id]
    return "#{base}_blob_#{reviewed_blob_id}" if %w[w9_approved w9_rejected].include?(action.to_s) && reviewed_blob_id.present?

    if action.to_s.include?('proof_submitted') || action.to_s.include?('proof_attached')
      proof_type = metadata['proof_type'] || metadata[:proof_type]
      submission_method = metadata['submission_method'] || metadata[:submission_method]
      blob_id = metadata['blob_id'] || metadata[:blob_id]

      # The blob ID distinguishes separate attachments of the same proof type.
      if action.to_s.include?('proof_attached') && blob_id
        return "#{base}_#{proof_type}_blob_#{blob_id}"
      elsif proof_type && submission_method
        return "#{base}_#{proof_type}_#{submission_method}"
      end
    end

    # The retired user ID keeps separate merges into one canonical user distinct within DEDUP_WINDOW.
    if action.to_s == 'duplicate_user_merged'
      merged_user_id = metadata['merged_user_id'] || metadata[:merged_user_id]
      return "#{base}_#{merged_user_id}" if merged_user_id.present?
    end

    # DuplicateReviewCases::CreateService keys cases by source, subject, reason codes, and candidate IDs.
    # One subject can therefore hold several open cases. Their IDs keep audit events distinct within DEDUP_WINDOW.
    if %w[
      duplicate_review_case_opened
      duplicate_review_case_resolved
      duplicate_review_case_pair_repointed
      duplicate_review_case_superseded
    ].include?(action.to_s)
      review_case_id = metadata['duplicate_review_case_id'] || metadata[:duplicate_review_case_id]
      return "#{base}_#{review_case_id}" if review_case_id.present?
    end

    # Flag toggles distinguish the flag, old and new values, and actor.
    # key? retains false after a JSON round trip. A || lookup would replace false with nil.
    if action.to_s == 'feature_flag_toggled'
      flag_name = metadata.key?('flag_name') ? metadata['flag_name'] : metadata[:flag_name]
      old_val   = metadata.key?('old_value') ? metadata['old_value'] : metadata[:old_value]
      new_val   = metadata.key?('new_value') ? metadata['new_value'] : metadata[:new_value]
      actor_id  = metadata.key?('admin_id')  ? metadata['admin_id']  : metadata[:admin_id]
      return "#{base}_#{flag_name}_#{old_val}_#{new_val}_#{actor_id}"
    end

    if %w[
      provider_info_request_revoked
      proof_resubmission_request_revoked
      cert_upload_request_revoked
      proof_resubmission_request_expired
      cert_upload_request_expired
      w9_upload_request_revoked
      w9_upload_request_expired
    ].include?(action.to_s)
      form_id = metadata['secure_request_form_id'] || metadata[:secure_request_form_id] ||
                metadata['vendor_secure_request_form_id'] || metadata[:vendor_secure_request_form_id]
      request_batch_id = metadata['request_batch_id'] || metadata[:request_batch_id]
      return "#{base}_#{form_id || request_batch_id}" if form_id.present? || request_batch_id.present?
    end

    if action.to_s == 'w9_details_changed'
      changed_fields = metadata['changed_fields'] || metadata[:changed_fields]
      return "#{base}_#{Array(changed_fields).sort.join('_')}" if changed_fields.present?
    end

    if %w[proof_resubmission_request_failed proof_review_follow_up_failed].include?(action.to_s)
      proof_review_id = metadata['proof_review_id'] || metadata[:proof_review_id]
      return "#{base}_#{proof_review_id}" if proof_review_id.present?
    end

    # A notification failure and a proof delivery failure must retain separate audit events within DEDUP_WINDOW.
    if action.to_s == 'application_post_creation_step_failed'
      step = metadata['step'] || metadata[:step]
      return "#{base}_#{step}" if step.present?
    end

    base
  end

  private_class_method :create_event_fingerprint
end
