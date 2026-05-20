# frozen_string_literal: true

module Applications
  # Consolidates event deduplication logic from multiple sources into a single, reliable service through
  # a flexible fingerprinting approach to identify and merge duplicate events based on their type, content, and timing.
  class EventDeduplicationService < BaseService
    # Time window for grouping events. Events within this window with the same fingerprint are considered duplicates.
    DEDUPLICATION_WINDOW = 1.minute

    # Deduplicates a collection of events from various sources.
    # @param events [Array<Notification, ApplicationStatusChange, Event>] The events to deduplicate.
    # @return [Array] A sorted, unique list of events.
    def deduplicate(events)
      return [] if events.blank?

      # Group events by a generated fingerprint and a time bucket.
      grouped_events = events.group_by do |event|
        [
          event_fingerprint(event),
          (event.created_at.to_i / DEDUPLICATION_WINDOW) * DEDUPLICATION_WINDOW
        ]
      end

      # From each group of duplicates, select the most representative event.
      grouped_events.values.map do |group|
        select_best_event(group)
      end.sort_by(&:created_at).reverse
    end

    private

    # Generates a consistent, descriptive fingerprint for an event to identify duplicates.
    # The fingerprint includes the event's primary action and relevant metadata.
    #
    # @param event [Object] The event to fingerprint.
    # @return [String] A unique fingerprint string.
    def event_fingerprint(event)
      # Never deduplicate application_created events
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
      when 'provider_info_request_revoked', 'proof_resubmission_request_revoked'
        [metadata['secure_request_form_id'], metadata['request_batch_id']].compact.join('-')
      when 'cert_upload_request_revoked'
        metadata['medical_provider_secure_request_form_id'].to_s
      end
    end

    # Normalizes the action name across different event types.
    #
    # @param event [Object] The event record.
    # @return [String] The normalized action name.
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

    # Selects the best event from a group of duplicates based on a priority system. The priority is:
    # ApplicationStatusChange > Event > Notification. If types are the same, the most recent event is chosen.
    #
    # @param group [Array] A group of duplicate events. @return [Object] The highest-priority event from the group.
    def select_best_event(group)
      group.max_by do |event|
        [priority_score(event), event.created_at]
      end
    end

    # Assigns a priority score to an event type to help select the best representation of a duplicate event. Higher scores are preferred.
    #
    # @param event [Object] The event to score. @return [Integer] The priority score.
    def priority_score(event)
      # Give highest priority to application_created events
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
