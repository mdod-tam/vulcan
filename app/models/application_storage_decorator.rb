# frozen_string_literal: true

# Views use attachment names without eager loading ActiveStorage blobs.
class ApplicationStorageDecorator
  attr_reader :application, :preloaded_attachments

  # preloaded_attachments is a Set of attachment names, or :not_preloaded.
  def initialize(application, preloaded_attachments = :not_preloaded)
    @application = application
    @preloaded_attachments = preloaded_attachments
    @metadata_cache = {}
  end

  delegate :id, to: :application

  delegate :application_date, to: :application

  delegate :user, to: :application

  delegate :status, to: :application

  delegate :income_proof_status, to: :application

  delegate :residency_proof_status, to: :application

  delegate :id_proof_status, to: :application

  delegate :medical_certification_status, to: :application

  # These accessors return the decorator. Use the named *_attached? methods for attachment existence.
  def income_proof
    self
  end

  def residency_proof
    self
  end

  def id_proof
    self
  end

  def medical_certification
    self
  end

  def attached?
    # The decorator needs an attachment name to answer this question.
    raise 'Use specific attachment methods instead (income_proof_attached?, residency_proof_attached?, etc.)'
  end

  def income_proof_attached?
    if application.respond_to?(:income_proof_attachment_changes_to_save) &&
       application.income_proof_attachment_changes_to_save.present?
      true
    elsif application.association(:income_proof_attachment).loaded?
      application.income_proof_attachment.present?
    else
      attachment_exists?('income_proof')
    end
  end

  def residency_proof_attached?
    if application.respond_to?(:residency_proof_attachment_changes_to_save) &&
       application.residency_proof_attachment_changes_to_save.present?
      true
    elsif application.association(:residency_proof_attachment).loaded?
      application.residency_proof_attachment.present?
    else
      attachment_exists?('residency_proof')
    end
  end

  def id_proof_attached?
    if application.respond_to?(:id_proof_attachment_changes_to_save) &&
       application.id_proof_attachment_changes_to_save.present?
      true
    elsif application.association(:id_proof_attachment).loaded?
      application.id_proof_attachment.present?
    else
      attachment_exists?('id_proof')
    end
  end

  def medical_certification_attached?
    if application.respond_to?(:medical_certification_attachment_changes_to_save) &&
       application.medical_certification_attachment_changes_to_save.present?
      true
    elsif application.association(:medical_certification_attachment).loaded?
      application.medical_certification_attachment.present?
    else
      attachment_exists?('medical_certification')
    end
  end

  private

  # The controller supplies attachment names. Missing preload data requires a database query.
  def attachment_exists?(name)
    @metadata_cache[:"#{name}_exists"] ||= if @preloaded_attachments == :not_preloaded
                                             # Report callers that omit attachment preload data.
                                             Rails.logger.warn "PERFORMANCE: Falling back to DB query for attachment existence: #{name} on App #{application.id}"
                                             Rails.logger.warn '  → This suggests attachment preloading failed in the controller'
                                             Rails.logger.warn '  → Check ApplicationDataLoading#preload_attachments_for_applications method'

                                             ActiveStorage::Attachment.exists?(record_type: 'Application',
                                                                               record_id: application.id,
                                                                               name: name)
                                           else
                                             @preloaded_attachments.include?(name.to_s)
                                           end
  end

  def method_missing(method_name, *, &)
    if application.respond_to?(method_name)
      application.send(method_name, *, &)
    else
      super
    end
  end

  def respond_to_missing?(method_name, include_private = false)
    application.respond_to?(method_name, include_private) || super
  end
end
