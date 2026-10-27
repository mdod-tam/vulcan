# frozen_string_literal: true

module Applications
  # Selects the certification-related events from an application's audit log and formats request events for display.
  class CertificationEventsService
    def initialize(application)
      @application = application
      @audit_log_builder = AuditLogBuilder.new(application)
    end

    # Certification-related events from the deduplicated audit log.
    def certification_events
      deduplicated_logs = @audit_log_builder.build_deduplicated_audit_logs

      deduplicated_logs.select { |event| certification_related_event?(event) }
    end

    # The request events among the certification events, as the hashes the admin views expect.
    def request_events
      events = certification_events

      request_events = events.select { |event| request_event?(event) }

      process_request_events_for_display(request_events)
    end

    private

    def certification_related_event?(event)
      case event
      when Notification
        certification_related_notification?(event)
      when ApplicationStatusChange
        certification_related_status_change?(event)
      when Event
        certification_related_event_record?(event)
      else
        false
      end
    end

    def certification_related_notification?(event)
      event.action.to_s.include?('certification')
    end

    def certification_related_status_change?(event)
      medical_certification_metadata?(event) ||
        status_contains_certification?(event)
    end

    def certification_related_event_record?(event)
      event.action.to_s.include?('certification') ||
        (event.metadata.is_a?(Hash) && event.metadata.to_s.include?('certification'))
    end

    def medical_certification_metadata?(event)
      return false unless event.metadata

      event.metadata[:change_type] == 'medical_certification' ||
        event.metadata['change_type'] == 'medical_certification'
    end

    def status_contains_certification?(event)
      event.from_status.to_s.include?('certification') ||
        event.to_status.to_s.include?('certification')
    end

    def request_event?(event)
      case event
      when Notification
        event.action == 'medical_certification_requested'
      when ApplicationStatusChange
        event.to_status == 'requested'
      when Event
        request_event_record?(event)
      else
        generic_request_event?(event)
      end
    end

    def request_event_record?(event)
      event.action == 'medical_certification_requested' ||
        (event.metadata.is_a?(Hash) && event.metadata['details'].to_s.include?('certification requested'))
    end

    def generic_request_event?(event)
      event.respond_to?(:metadata) &&
        event.metadata.is_a?(Hash) &&
        event.metadata.to_s.include?('certification requested')
    end

    def process_request_events_for_display(events)
      unique_requests = {}

      events.each do |event|
        timestamp = determine_timestamp(event)
        timestamp_key = timestamp.strftime('%Y-%m-%d %H:%M')
        actor_name = determine_actor_name(event)
        submission_method = determine_submission_method(event)

        next unless !unique_requests.key?(timestamp_key) ||
                    (submission_method.present? && unique_requests[timestamp_key][:submission_method].blank?)

        unique_requests[timestamp_key] = {
          timestamp: timestamp,
          actor_name: actor_name,
          submission_method: submission_method
        }
      end
      unique_requests.values.sort_by { |r| r[:timestamp] }.reverse
    end

    def determine_timestamp(event)
      timestamp = event.created_at
      if event.respond_to?(:metadata) && event.metadata.is_a?(Hash) && event.metadata['timestamp'].present?
        begin
          timestamp = Time.zone.parse(event.metadata['timestamp'])
        rescue StandardError
          # An unparseable timestamp keeps the event's created_at.
        end
      end
      timestamp
    end

    def determine_actor_name(event)
      if event.is_a?(Notification)
        event.actor&.full_name || 'System'
      elsif event.is_a?(ApplicationStatusChange) || event.is_a?(Event)
        event.user&.full_name || 'System'
      else
        'System'
      end
    end

    def determine_submission_method(event)
      return unless event.respond_to?(:metadata) && event.metadata.is_a?(Hash)

      event.metadata['submission_method'] || event.metadata['method'] || event.metadata['delivery_method']
    end
  end
end
