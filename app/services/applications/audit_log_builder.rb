# frozen_string_literal: true

module Applications
  class AuditLogBuilder < BaseService
    attr_reader :application

    def initialize(application)
      super()
      @application = application
    end

    # Build combined audit logs from multiple sources, including creation event
    def build_audit_logs
      return [] unless application

      # Combine creation event with other events
      events = [build_creation_event] + combined_events
      events.sort_by(&:created_at).reverse
    rescue StandardError => e
      Rails.logger.error "Failed to build audit logs: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      add_error("Failed to build audit logs: #{e.message}")
      []
    end

    # Build deduplicated audit logs using the EventDeduplicationService
    def build_deduplicated_audit_logs
      return [] unless application

      # Collect all events from various sources
      events = build_audit_logs

      # Use the deduplication service to remove duplicates
      deduped = EventDeduplicationService.new.deduplicate(events)

      # Conditionally preload associations used by the view to avoid N+1
      # without over-eager loading when those records are not displayed.
      notifications = deduped.select { |e| e.is_a?(Notification) }
      ActiveRecord::Associations::Preloader.new.preload(notifications, :actor) if notifications.any?

      deduped
    rescue StandardError => e
      Rails.logger.error "Failed to build deduplicated audit logs: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      add_error("Failed to build deduplicated audit logs: #{e.message}")
      []
    end

    private

    # Construct the application creation event
    def build_creation_event
      # Prefer the persisted creation event (logged with correct actor: admin for paper, user for portal)
      persisted = Event
                  .select('id, user_id, action, created_at, metadata, auditable_type, auditable_id')
                  .includes(:user)
                  .where(action: 'application_created', auditable_type: 'Application', auditable_id: application.id)
                  .order(created_at: :asc)
                  .first

      return persisted if persisted.present?

      # Fallback: locate persisted events that reference the application via metadata.application_id
      persisted_by_metadata = Event
                              .select('id, user_id, action, created_at, metadata, auditable_type, auditable_id')
                              .includes(:user)
                              .where(action: 'application_created')
                              .where("(metadata->>'application_id' = ?) OR metadata @> ?", application.id.to_s, { application_id: application.id }.to_json)
                              .order(created_at: :asc)
                              .first

      return persisted_by_metadata if persisted_by_metadata.present?

      # Fallback for legacy records where no persisted creation event exists
      Event.new(
        user: application.user,
        auditable: application,
        action: 'application_created',
        created_at: application.created_at,
        metadata: {
          'submission_method' => application.submission_method,
          'initial_status' => application.status
        }
      )
    end

    # Aggregate events from all sources
    def combined_events
      [
        load_proof_reviews,
        load_status_changes,
        load_notifications,
        load_application_events,
        load_user_profile_changes
      ].flatten
    end

    # Load proof reviews with minimal eager loading
    def load_proof_reviews
      ProofReview
        .select('id, application_id, admin_id, proof_type, status, created_at, reviewed_at, rejection_reason, notes')
        .includes(admin: []) # Include the admin but not role_capabilities
        .where(application_id: application.id)
        .order(created_at: :desc)
        .to_a
    end

    # Load status changes with minimal eager loading
    def load_status_changes
      ApplicationStatusChange
        .select('id, application_id, user_id, from_status, to_status, created_at, metadata, notes')
        .includes(user: []) # Include the user but not role_capabilities
        .where(application_id: application.id)
        .order(created_at: :desc)
        .to_a
    end

    # Load notifications without eager loading; we conditionally preload
    # actor after deduplication to avoid unnecessary eager loading.
    def load_notifications
      Notification
        .select('id, recipient_id, actor_id, notifiable_id, notifiable_type, action, read_at, created_at, message_id, delivery_status, metadata')
        .where(notifiable_type: 'Application', notifiable_id: application.id)
        .where(action: %w[
                 medical_certification_requested
                 medical_certification_received
                 medical_certification_approved
                 medical_certification_rejected
                 review_requested
                 documents_requested
               ])
        .order(created_at: :desc)
        .to_a
    end

    # Load application events with minimal eager loading
    def load_application_events
      Event
        .select('id, user_id, action, created_at, metadata, auditable_type, auditable_id')
        .includes(:user) # Include just the user without role_capabilities
        .where(
          "action IN (?) AND (metadata->>'application_id' = ? OR metadata @> ? OR (auditable_type = 'Application' AND auditable_id = ?))",
          %w[
            voucher_assigned voucher_redeemed voucher_expired voucher_cancelled
            application_created evaluator_assigned trainer_assigned application_auto_approved
            medical_certification_requested medical_certification_status_changed
            alternate_contact_updated
          ],
          application.id.to_s,
          { application_id: application.id }.to_json,
          application.id
        )
        .order(created_at: :desc)
        .to_a
    end

    # Load user profile changes with minimal eager loading
    def load_user_profile_changes
      user_ids = [application.user_id]
      user_ids << application.managing_guardian_id if application.managing_guardian_id.present?

      Event
        .select('id, user_id, action, created_at, metadata')
        .includes(:user)
        .where(action: %w[profile_updated profile_updated_by_guardian])
        .where(
          "(action = 'profile_updated' AND user_id IN (?)) OR (action = 'profile_updated_by_guardian' AND metadata->>'user_id' IN (?))",
          user_ids, user_ids.map(&:to_s)
        )
        .order(created_at: :desc)
        .to_a
    end
  end
end
