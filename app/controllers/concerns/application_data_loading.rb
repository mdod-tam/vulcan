# frozen_string_literal: true

module ApplicationDataLoading
  extend ActiveSupport::Concern

  DEFAULT_ATTACHMENT_NAMES = %w[income_proof residency_proof id_proof disability_certification].freeze

  # @param application_id [Integer, String] The ID of the application to load
  # @return [Application] The loaded application
  def load_application_with_attachments(application_id)
    application = Application.find(application_id)

    # These queries omit variant records.
    preload_application_attachments(application)

    application
  end

  # These queries read attachment IDs and blob metadata without populating association caches.
  # @param application [Application] Application whose attachment metadata the queries read
  def preload_application_attachments(application)
    attachment_ids = ActiveStorage::Attachment
                     .where(record_type: 'Application', record_id: application.id)
                     .select(:id, :name, :blob_id)
                     .pluck(:id)

    return unless attachment_ids.any?

    ActiveStorage::Blob
      .joins('INNER JOIN active_storage_attachments ON active_storage_blobs.id = active_storage_attachments.blob_id')
      .where(active_storage_attachments: { id: attachment_ids })
      .select('active_storage_blobs.id, active_storage_blobs.filename, ' \
              'active_storage_blobs.content_type, active_storage_blobs.byte_size, ' \
              'active_storage_blobs.checksum, active_storage_blobs.created_at, ' \
              'active_storage_blobs.service_name, active_storage_blobs.metadata')
      .to_a
  end

  # @param application [Application] Application whose related records the queries read
  def load_application_show_associations(application)
    ApplicationStatusChange.where(application_id: application.id)
                           .includes(:user)
                           .load

    ProofReview.where(application_id: application.id)
               .includes(:admin)
               .order(created_at: :desc)
               .load

    ApplicationNote.where(application_id: application.id)
                   .includes(:admin, :assigned_to)
                   .recent_first
                   .load

    User.find_by(id: application.user_id) if application.user_id.present?

    load_training_associations(application) if application.status_approved?
  end

  # @param application [Application] Application for the evaluation and training relations
  def load_training_associations(application)
    application.evaluations.preload(:evaluator) if application.respond_to?(:evaluations)
    return unless application.respond_to?(:training_sessions)

    application.training_sessions.preload(:trainer).order(created_at: :desc)
  end

  # @param applications [Array<Application>] Applications whose attachment names the query reads
  # @param attachment_names [Array<String>, nil] Attachment names, or nil for controller defaults
  # @return [Hash] Hash mapping application_id to Set of attachment names
  def preload_attachments_for_applications(applications, attachment_names: nil)
    attachment_names = resolve_attachment_names(attachment_names)
    ids = applications.map(&:id)
    return {} if ids.empty?

    fetch_and_process_attachments(ids, attachment_names)
  end

  # Turbo stream updates use a fresh application instance.
  # @param application [Application] Application whose ID selects the fresh instance
  # @return [Application] A fresh application instance
  def reload_application_and_associations(application)
    reloaded_application = load_application_with_attachments(application.id)
    load_training_associations(reloaded_application) if reloaded_application.status_approved?
    reloaded_application
  end

  # @param applications [Array<Application>] Applications to decorate
  # @param attachment_index [Hash] Hash mapping application_id to attachment names
  # @return [Array<ApplicationStorageDecorator>] Decorated applications
  def decorate_applications_with_storage(applications, attachment_index)
    applications.map do |app|
      ApplicationStorageDecorator.new(app, attachment_index[app.id] || Set.new)
    end
  end

  # Applications newest first, without the excluded statuses.
  # @param exclude_statuses [Array<Symbol>] Statuses to exclude (default: [:draft, :rejected, :archived])
  # @return [ActiveRecord::Relation] The base scope
  def build_application_base_scope(exclude_statuses: %i[draft rejected archived])
    scope = Application.includes(
      # Views read guardian relationships for each application.
      user: :guardian_relationships_as_dependent
    )

    scope = scope.where.not(status: exclude_statuses) if exclude_statuses.any?

    scope.order(application_date: :desc, id: :desc)
  end

  private

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

  # @param ids [Array<Integer>] Application IDs
  # @param attachment_names [Array<String>] Attachment names to fetch
  # @return [Array<Array>] Raw attachment data
  def fetch_attachments_data(ids, attachment_names)
    ActiveStorage::Attachment
      .where(record_type: 'Application', record_id: ids, name: attachment_names)
      .pluck(:record_id, :name)
  end

  # @param attachments_data [Array] The fetched attachment data
  # @param ids [Array<Integer>] Application IDs
  def log_attachments_preload(attachments_data, ids)
    return unless ENV['VERBOSE_TESTS']

    Rails.logger.debug { "Preloaded #{attachments_data.length} attachments for #{ids.length} applications" }
  end

  # @param attachments_data [Array<Array>] Raw attachment data
  # @return [Hash] Hash mapping application_id to Set of attachment names
  def transform_attachments_data(attachments_data)
    attachments_data.group_by(&:first)
                    .transform_values { |rows| rows.to_set(&:second) }
  end

  # @param ids [Array<Integer>] All application IDs
  # @param result [Hash] Result hash with application IDs as keys
  def log_missing_attachments(ids, result)
    return unless ENV['VERBOSE_TESTS']

    missing_attachments = ids - result.keys
    return unless missing_attachments.any?

    Rails.logger.debug { "Applications with no attachments: #{missing_attachments}" }
  end

  # @param error [StandardError] The error that occurred
  # @param ids [Array<Integer>] Application IDs being processed
  # @return [Hash] Empty hash as fallback
  def handle_attachments_error(error, ids)
    Rails.logger.error "Error preloading attachments for applications #{ids}: #{error.class.name}"
    {}
  end
end
