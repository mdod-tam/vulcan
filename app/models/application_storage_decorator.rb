# frozen_string_literal: true

# Decorator for Application objects to prevent unnecessary ActiveStorage eager loading
# when displaying attachments in views
class ApplicationStorageDecorator
  attr_reader :application, :preloaded_attachments

  # Accept preloaded attachment existence data (a Set of attachment names)
  def initialize(application, preloaded_attachments = :not_preloaded)
    @application = application
    @preloaded_attachments = preloaded_attachments
    # Cache attachment metadata to avoid repeated DB queries
    @metadata_cache = {}
  end

  # Basic application attributes that should be delegated directly

  delegate :id, to: :application

  delegate :application_date, to: :application

  delegate :user, to: :application

  delegate :status, to: :application

  delegate :income_proof_status, to: :application

  delegate :residency_proof_status, to: :application

  delegate :medical_certification_status, to: :application

  # ActiveStorage attachment accessors that avoid triggering eager loading
  # Direct access to attachments will use safe versions instead
  def income_proof
    self
  end

  def residency_proof
    self
  end

  def medical_certification
    self
  end

  def attached?
    # Used as a fallback when the specific attachment method is not used
    # This should generally not be called directly
    raise 'Use specific attachment methods instead (income_proof_attached?, residency_proof_attached?, etc.)'
  end

  # Safe method to check if income proof is attached without eager loading blob associations
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

  # Safe method to check if residency proof is attached without eager loading blob associations
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

  # Safe method to check if medical certification is attached without eager loading
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

  # Helper methods for fetching attachment data safely (removed unused helpers)

  # Removed unused attachment_context accessors

  private

  # Use preloaded data if available, otherwise fallback (though fallback shouldn't be needed with controller change)
  def attachment_exists?(name)
    @metadata_cache[:"#{name}_exists"] ||= if @preloaded_attachments == :not_preloaded
                                             # Fallback query - indicates attachment preloading failed
                                             Rails.logger.warn "PERFORMANCE: Falling back to DB query for attachment existence: #{name} on App #{application.id}"
                                             Rails.logger.warn '  → This suggests attachment preloading failed in the controller'
                                             Rails.logger.warn '  → Check ApplicationDataLoading#preload_attachments_for_applications method'

                                             ActiveStorage::Attachment.exists?(record_type: 'Application',
                                                                               record_id: application.id,
                                                                               name: name)
                                           else
                                             # Use the preloaded set of attachment names to determine existence
                                             @preloaded_attachments.include?(name.to_s)
                                           end
  end

  # Removed unused safe_attachment_attribute

  # Removed unused attachment_metadata helper

  # Pass through method_missing to the original application for methods we don't override
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
