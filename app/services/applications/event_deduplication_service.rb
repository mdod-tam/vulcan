# frozen_string_literal: true

module Applications
  # Merges duplicate events from mixed sources by fingerprint and time bucket.
  class EventDeduplicationService < BaseService
    # Groups use fixed buckets, not a sliding window.
    # Duplicates on two sides of a bucket boundary both stay.
    DEDUPLICATION_WINDOW = 1.minute

    # @param events [Array<Notification, ApplicationStatusChange, Event, ProofReview>]
    # @return [Array] one event per duplicate group, newest first
    def deduplicate(events)
      return [] if events.blank?

      grouped_events = events.group_by do |event|
        [
          event_fingerprint(event),
          (event.created_at.to_i / DEDUPLICATION_WINDOW) * DEDUPLICATION_WINDOW
        ]
      end

      grouped_events.values.map do |group|
        select_best_event(group)
      end.sort_by(&:created_at).reverse
    end

    private

    # Events with equal fingerprints in one bucket are duplicates.
    def event_fingerprint(event)
      # The record id makes each application_created event unique.
      return "application_created_#{event.id}" if event.respond_to?(:action) && event.action == 'application_created'

      action = generic_action(event)
      details = fingerprint_details(event)
      [action, details].compact.join('_').presence || "default_fingerprint_#{event.class.name.underscore}_#{event.id || event.created_at.to_i}"
    end

    def fingerprint_details(event)
      case event
      when ApplicationStatusChange
        fingerprint_for_status_change(event)
      when Notification
        fingerprint_for_notification(event)
      when Event
        fingerprint_for_event(event)
      when ->(e) { e.respond_to?(:action) && e.action&.include?('proof_submitted') }
        fingerprint_for_proof_submission(event)
      when ProofReview
        fingerprint_for_proof_review(event)
      end
    end

    def fingerprint_for_status_change(event)
      if event.metadata&.[](:change_type) == 'medical_certification' ||
         event.metadata&.[]('change_type') == 'medical_certification'
        nil
      else
        "#{event.from_status}-#{event.to_status}"
      end
    end

    def fingerprint_for_proof_submission(event)
      "#{event.metadata['proof_type']}-#{event.metadata['submission_method']}"
    end

    def fingerprint_for_proof_review(event)
      "#{event.proof_type}-#{event.status}"
    end

    def fingerprint_for_notification(event)
      metadata = event.metadata.is_a?(Hash) ? event.metadata.stringify_keys : {}

      case event.action
      when 'provider_info_requested', 'proof_resubmission_requested'
        [event.recipient_id, metadata['secure_request_form_id'], metadata['request_batch_id']].compact.join('-')
      when 'cert_upload_requested'
        metadata['medical_provider_secure_request_form_id'].to_s
      end
    end

    def fingerprint_for_event(event)
      metadata = event.metadata.is_a?(Hash) ? event.metadata.stringify_keys : {}

      case event.action
      when 'duplicate_review_case_opened', 'duplicate_review_case_resolved', 'duplicate_review_case_resumed'
        metadata['duplicate_review_case_id'].to_s
      when 'provider_info_request_revoked', 'proof_resubmission_request_revoked'
        [metadata['secure_request_form_id'], metadata['request_batch_id']].compact.join('-')
      when 'cert_upload_request_revoked'
        metadata['medical_provider_secure_request_form_id'].to_s
      when 'proof_resubmission_request_failed'
        metadata['proof_review_id'].to_s
      when 'alternate_contact_updated', 'medical_provider_info_updated'
        # Each stored change is distinct. AuditEventService already drops identical repeats.
        event.id.to_s
      when 'shipment_added', 'shipment_corrected', 'fulfillment_mode_changed'
        # Each fulfillment change has its own operation id; two in one minute are both real.
        metadata['operation_id'].presence || event.id.to_s
      end
    end

    def generic_action(event)
      case event
      when Notification, Event
        event.action.to_s.gsub(/_proof_submitted$/, '_submission')
      when ApplicationStatusChange
        if event.metadata&.[](:change_type) == 'medical_certification' ||
           event.metadata&.[]('change_type') == 'medical_certification'
          "medical_certification_#{event.to_status}"
        else
          "status_change_#{event.to_status}"
        end
      when ProofReview
        "proof_#{event.status}"
      else
        event.class.name.underscore
      end
    end

    # Highest priority_score wins. The newest event breaks a tie.
    def select_best_event(group)
      group.max_by do |event|
        [priority_score(event), event.created_at]
      end
    end

    def priority_score(event)
      return 4 if event.respond_to?(:action) && event.action == 'application_created'

      case event
      when ApplicationStatusChange
        3
      when ProofReview, Event
        2
      when Notification
        1
      else
        0
      end
    end
  end
end
