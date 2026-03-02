# frozen_string_literal: true

module ApplicationDataLoading
  extend ActiveSupport::Concern

  # Preload attachment names
  DEFAULT_ATTACHMENT_NAMES = %w[income_proof residency_proof medical_certification].freeze

  # Load an application with optimized attachment preloading
  # @param application_id [Integer] The ID of the application to load
  # @return [Application] The loaded application
  def load_application_with_attachments(application_id)
    # Load application first, without eager loading anything
    application = Application.find(application_id)

    # Preload the attachment metadata without loading associated models or variant records
    preload_application_attachments(application)

    application
  end

  # Preload attachment metadata for a single application
  # @param application [Application] The application to preload attachments for
  def preload_application_attachments(application)
    attachment_ids = ActiveStorage::Attachment
                     .where(record_type: 'Application', record_id: application.id)
                     .select(:id, :name, :blob_id)
                     .pluck(:id)

    return unless attachment_ids.any?

    # Make sure blobs are accessible with all required attributes
    ActiveStorage::Blob
      .joins('INNER JOIN active_storage_attachments ON active_storage_blobs.id = active_storage_attachments.blob_id')
      .where(active_storage_attachments: { id: attachment_ids })
      .select('active_storage_blobs.id, active_storage_blobs.filename, ' \
              'active_storage_blobs.content_type, active_storage_blobs.byte_size, ' \
              'active_storage_blobs.checksum, active_storage_blobs.created_at, ' \
              'active_storage_blobs.service_name, active_storage_blobs.metadata')
      .to_a
  end

  # Load associations specifically needed for application show views
  # @param application [Application] The application to load associations for
  def load_application_show_associations(application)
    # Load status changes directly – they're always needed
    ApplicationStatusChange.where(application_id: application.id)
                           .includes(:user)
                           .load

    # Load proof reviews that are needed
    ProofReview.where(application_id: application.id)
               .includes(:admin)
               .order(created_at: :desc)
               .load

    # Access user if needed (for caching, if necessary)
    User.find_by(id: application.user_id) if application.user_id.present?

    # Load training-related data for approved applications
    load_training_associations(application) if application.status_approved?
  end

  # Load training-related associations for approved applications
  # @param application [Application] The application to load training data for
  def load_training_associations(application)
    application.evaluations.preload(:evaluator) if application.respond_to?(:evaluations)
    return unless application.respond_to?(:training_sessions)

    application.training_sessions.preload(:trainer).order(created_at: :desc)
  end

  # Preload attachments for multiple applications efficiently
  # @param applications [Array<Application>] Applications to preload attachments for
  # @param attachment_names [Array<String>] Names of attachments to preload
  # @return [Hash] Hash mapping application_id to Set of attachment names
  def preload_attachments_for_applications(applications, attachment_names: nil)
    attachment_names = resolve_attachment_names(attachment_names)
    ids = applications.map(&:id)
    return {} if ids.empty?

    fetch_and_process_attachments(ids, attachment_names)
  end

  # Load proof history data for income and residency proofs
  # @param application [Application] The application to load proof history for
  # @return [Hash] Hash with :income and :residency keys containing history data
  def load_proof_histories(application)
    {
      income: load_proof_history_for_type(application, :income),
      residency: load_proof_history_for_type(application, :residency)
    }
  end

  # Load proof history for a specific proof type
  # @param application [Application] The application
  # @param type [Symbol] The proof type (:income or :residency)
  # @return [Hash] Hash containing reviews and audits
  def load_proof_history_for_type(application, type)
    {
      reviews: filter_and_sort_by_type(application.proof_reviews, type, :reviewed_at),
      audits: filter_and_sort_by_type(
        application.events.where(action: 'proof_submitted', metadata: { proof_type: type }),
        type,
        :created_at
      )
    }
  rescue StandardError => e
    Rails.logger.error "Failed to load #{type} proof history: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    { reviews: [], audits: [], error: true }
  end

  # Reload application and its associations (used for turbo stream updates)
  # @param application [Application] The application to reload
  # @return [Application] The reloaded application
  def reload_application_and_associations(application)
    reloaded_application = load_application_with_attachments(application.id)
    load_training_associations(reloaded_application) if reloaded_application.status_approved?
    reloaded_application
  end

  # Decorates applications with storage information
  # @param applications [Array<Application>] Applications to decorate
  # @param attachment_index [Hash] Hash mapping application_id to attachment names
  # @return [Array<ApplicationStorageDecorator>] Decorated applications
  def decorate_applications_with_storage(applications, attachment_index)
    applications.map do |app|
      ApplicationStorageDecorator.new(app, attachment_index[app.id] || Set.new)
    end
  end

  # Build a base scope for application queries with common includes
  # @param exclude_statuses [Array<Symbol>] Statuses to exclude (default: [:draft, :rejected, :archived])
  # @return [ActiveRecord::Relation] The base scope
  #
  # Usage:
  #   # Default behavior: exclude drafts, rejected, archived
  #   build_application_base_scope
  #
  #   # Include drafts by removing from exclusions
  #   build_application_base_scope(exclude_statuses: [:rejected, :archived])
  #
  #   # Custom exclusion list
  #   build_application_base_scope(exclude_statuses: [:rejected])
  def build_application_base_scope(exclude_statuses: %i[draft rejected archived])
    scope = Application.includes(
      :user,
      :managing_guardian,
      # Preload guardian_relationships to avoid N+1 when checking relationships in views
      user: :guardian_relationships_as_dependent
    )

    scope = scope.where.not(status: exclude_statuses) if exclude_statuses.any?

    # Default ordering: most recent applications first
    scope.order(application_date: :desc, id: :desc)
  end

  # Load notifications for an application with specific actions
  # @param application [Application] The application
  # @param actions [Array<String>] Notification actions to load
  # @return [ActiveRecord::Relation] Notifications
  def load_application_notifications(application, actions: nil)
    actions ||= %w[
      medical_certification_requested medical_certification_received
      medical_certification_approved medical_certification_rejected
      review_requested documents_requested proof_approved proof_rejected
    ]

    Notification
      .select('id, recipient_id, actor_id, notifiable_id, notifiable_type, action, read_at, ' \
              'created_at, message_id, delivery_status, metadata')
      .where(notifiable_type: 'Application', notifiable_id: application.id)
      .where(action: actions)
      .order(created_at: :desc)
  end

  # Load application events with specific actions
  # @param application [Application] The application
  # @param actions [Array<String>] Event actions to load
  # @return [ActiveRecord::Relation] The events
  def load_application_events(application, actions: nil)
    actions ||= %w[
      voucher_assigned voucher_redeemed voucher_expired voucher_cancelled
      application_created evaluator_assigned trainer_assigned application_auto_approved
    ]

    Event
      .select('id, user_id, action, created_at, metadata')
      .includes(:user)
      .where("action IN (?) AND (metadata->>'application_id' = ? OR metadata @> ?)",
             actions,
             application.id.to_s,
             { application_id: application.id }.to_json)
      .order(created_at: :desc)
  end

  private

  # Resolve attachment names from parameter or constant
  # @param attachment_names [Array<String>, nil] Names to use or nil for default
  # @return [Array<String>] Resolved attachment names
  def resolve_attachment_names(attachment_names)
    return attachment_names if attachment_names

    begin
      self.class.const_get(:WANTED_ATTACHMENT_NAMES)
    rescue StandardError
      DEFAULT_ATTACHMENT_NAMES
    end
  end

  # Fetch and process attachment data with error handling
  # @param ids [Array<Integer>] Application IDs
  # @param attachment_names [Array<String>] Attachment names to fetch
  # @return [Hash] Hash mapping application_id to Set of attachment names
  def fetch_and_process_attachments(ids, attachment_names)
    attachments_data = fetch_attachments_data(ids, attachment_names)
    log_attachments_preload(attachments_data, ids)

    result = transform_attachments_data(attachments_data)
    log_missing_attachments(ids, result)

    result
  rescue StandardError => e
    handle_attachments_error(e, ids)
  end

  # Fetch raw attachment data from database
  # @param ids [Array<Integer>] Application IDs
  # @param attachment_names [Array<String>] Attachment names to fetch
  # @return [Array<Array>] Raw attachment data
  def fetch_attachments_data(ids, attachment_names)
    ActiveStorage::Attachment
      .where(record_type: 'Application', record_id: ids, name: attachment_names)
      .pluck(:record_id, :name)
  end

  # Log attachment preloading information
  # @param attachments_data [Array] The fetched attachment data
  # @param ids [Array<Integer>] Application IDs
  def log_attachments_preload(attachments_data, ids)
    return unless ENV['VERBOSE_TESTS']

    Rails.logger.debug { "Preloaded #{attachments_data.length} attachments for #{ids.length} applications" }
  end

  # Transform raw attachment data into structured result
  # @param attachments_data [Array<Array>] Raw attachment data
  # @return [Hash] Hash mapping application_id to Set of attachment names
  def transform_attachments_data(attachments_data)
    attachments_data.group_by(&:first)
                    .transform_values { |rows| rows.to_set(&:second) }
  end

  # Log applications with missing attachments
  # @param ids [Array<Integer>] All application IDs
  # @param result [Hash] Result hash with application IDs as keys
  def log_missing_attachments(ids, result)
    return unless ENV['VERBOSE_TESTS']

    missing_attachments = ids - result.keys
    return unless missing_attachments.any?

    Rails.logger.debug { "Applications with no attachments: #{missing_attachments}" }
  end

  # Handle errors during attachment processing
  # @param error [StandardError] The error that occurred
  # @param ids [Array<Integer>] Application IDs being processed
  # @return [Hash] Empty hash as fallback
  def handle_attachments_error(error, ids)
    Rails.logger.error "Error preloading attachments for applications #{ids}: #{error.message}"
    Rails.logger.error error.backtrace.join("\n") if ENV['VERBOSE_TESTS']
    {}
  end

  # Filter and sorts a collection by proof type
  # @param collection [ActiveRecord::Relation] The collection to filter
  # @param type [Symbol] The proof type to filter by
  # @param sort_method [Symbol] The method to sort by
  # @return [Array] Filtered and sorted collection
  def filter_and_sort_by_type(collection, type, sort_method)
    collection.select { |item| item.proof_type.to_sym == type.to_sym }
              .sort_by(&sort_method)
              .reverse
  end
end
