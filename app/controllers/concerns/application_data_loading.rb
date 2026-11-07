# frozen_string_literal: true

module ApplicationDataLoading
  extend ActiveSupport::Concern

  DEFAULT_ATTACHMENT_NAMES = %w[income_proof residency_proof id_proof disability_certification].freeze

  # @param applications [Array<Application>] Applications whose attachment names the query reads
  # @param attachment_names [Array<String>, nil] Attachment names, or nil for controller defaults
  # @return [Hash] Hash mapping application_id to Set of attachment names
  def preload_attachments_for_applications(applications, attachment_names: nil)
    attachment_names = resolve_attachment_names(attachment_names)
    ids = applications.map(&:id)
    return {} if ids.empty?

    fetch_and_process_attachments(ids, attachment_names)
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
    attachment_names || DEFAULT_ATTACHMENT_NAMES
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
end
