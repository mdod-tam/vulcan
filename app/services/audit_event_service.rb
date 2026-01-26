# frozen_string_literal: true

# app/services/audit_event_service.rb
class AuditEventService < BaseService
  # Time window for preventing duplicate event creation.
  # EventDeduplicationService handles sophisticated deduplication for display purposes.
  DEDUP_WINDOW = 5.seconds

  # Logs a distinct system event and prevents duplicates within the DEDUP_WINDOW.
  #
  # @param action [String] The specific action being performed (e.g., 'proof_approved').
  # @param actor [User] The user performing the action.
  # @param auditable [ApplicationRecord, nil] The primary record being acted upon (optional).
  # @param metadata [Hash] Additional context for the event.
  # @param created_at [Time] (Optional) The timestamp for the event, for testing purposes.
  # @return [Event, nil] The created Event record or nil if deduplicated.
  def self.log(action:, actor:, auditable: nil, metadata: {}, created_at: nil)
    # TODO: for more robustness add a partial unique index in the database on
    # (action, auditable_type, auditable_id) for recent events.

    # Skip deduplication for application_created - these should always be logged
    skip_deduplication_actions = %w[application_created]

    # Skip deduplication if auditable is nil (can't dedupe without record reference)
    should_check_duplicates = auditable.present? && skip_deduplication_actions.exclude?(action.to_s)

    if should_check_duplicates && recent_duplicate_exists?(action: action, auditable: auditable, metadata: metadata)
      Rails.logger.info "AuditEventService: Duplicate event '#{action}' for #{auditable.class.name} ##{auditable.id} suppressed."
      return nil
    end

    # Use reverse_merge to ensure caller-provided metadata is not overwritten; namespace internal keys to avoid conflicts.
    final_metadata = metadata.reverse_merge(
      __service_generated: true
    )

    event_attributes = {
      user: actor,
      action: action.to_s,
      auditable: auditable,
      metadata: final_metadata
    }

    # Only set created_at if it's provided, primarily for testing
    event_attributes[:created_at] = created_at if created_at.present?

    # Debug log for application_created events
    if action.to_s == 'application_created' && auditable.present?
      Rails.logger.debug { "AuditEventService: Creating application_created event for application #{auditable.id}" }
      Rails.logger.debug { "Metadata: #{final_metadata.inspect}" }
    end

    event = Event.create!(event_attributes)

    # Debug for application_created event
    if action.to_s == 'application_created' && auditable.present? && event.persisted?
      Rails.logger.debug { "AuditEventService: Successfully created event #{event.id} for application #{auditable.id}" }
    end

    event
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.error "AuditEventService: Failed to log event: #{e.message}"
    Rails.logger.error "Event attributes: #{event_attributes.inspect}"
    raise # Re-raise the exception to make it visible in tests
  end

  # Checks if a similar event for the same record was created within the DEDUP_WINDOW.
  # Enhanced to consider metadata differences to allow legitimate different events.
  def self.recent_duplicate_exists?(action:, auditable:, metadata: {})
    # Skip deduplication if auditable is nil
    return false if auditable.nil?

    # Create a fingerprint that includes meaningful metadata differences
    fingerprint = create_event_fingerprint(action, metadata)

    Event.where(action: action.to_s, auditable: auditable)
         .where(created_at: DEDUP_WINDOW.ago..)
         .any? { |event| create_event_fingerprint(event.action, event.metadata) == fingerprint }
  end

  # Create a fingerprint that distinguishes between meaningfully different events
  def self.create_event_fingerprint(action, metadata)
    base = action.to_s

    # For proof submission events, include proof_type and submission_method
    if action.to_s.include?('proof_submitted') || action.to_s.include?('proof_attached')
      proof_type = metadata['proof_type'] || metadata[:proof_type]
      submission_method = metadata['submission_method'] || metadata[:submission_method]
      blob_id = metadata['blob_id'] || metadata[:blob_id]

      # Include blob_id for proof attachment events to ensure we only create one event per actual attachment
      if action.to_s.include?('proof_attached') && blob_id
        return "#{base}_#{proof_type}_blob_#{blob_id}"
      elsif proof_type && submission_method
        return "#{base}_#{proof_type}_#{submission_method}"
      end
    end

    # For profile update events, include which fields changed AND their new values
    # This allows different changes to the same fields while deduplicating identical saves
    if action.to_s.include?('profile_updated') || action.to_s == 'profile_created_by_admin_via_paper'
      changes = metadata['changes'] || metadata[:changes]
      if changes.present?
        # Create fingerprint based on fields + new values to distinguish different actual changes
        # Hash the values to keep fingerprint size reasonable
        changes_hash = changes.map { |k, v| "#{k}:#{v['new'].to_s[0..50]}" }.sort.join('|')
        fingerprint_hash = Digest::MD5.hexdigest(changes_hash)
        return "#{base}_#{fingerprint_hash}"
      end
    end

    # For other events, use just the base action
    base
  end

  private_class_method :create_event_fingerprint
end
