# frozen_string_literal: true

# Records old and new values when alternate contact or medical provider
# fields change, so staff can see what was replaced and by whom.
module ContactChangeAudit
  extend ActiveSupport::Concern

  ALTERNATE_CONTACT_FIELDS = %w[alternate_contact_name alternate_contact_phone alternate_contact_email].freeze
  MEDICAL_PROVIDER_FIELDS = %w[medical_provider_name medical_provider_phone medical_provider_fax medical_provider_email].freeze

  included do
    # Audit context for a medical provider change that comes from a public secure form.
    attr_accessor :medical_provider_change_source

    # Provider values typed into a draft are not yet on file, so only changes to a
    # submitted application are recorded.
    after_update :log_medical_provider_changes, if: :medical_provider_change_on_submitted_application?
    after_save :log_alternate_contact_changes, if: :saved_change_to_alternate_contact?
  end

  def saved_change_to_alternate_contact?
    ALTERNATE_CONTACT_FIELDS.any? { |field| saved_change_to_attribute?(field) }
  end

  def log_alternate_contact_changes
    changes = saved_field_changes(ALTERNATE_CONTACT_FIELDS)
    return if changes.blank?

    AuditEventService.log(
      action: 'alternate_contact_updated',
      actor: Current.user || user,
      auditable: self,
      metadata: { changes: changes, changed_by: Current.user&.id }
    )
  rescue StandardError => e
    Rails.logger.error "Failed to log alternate contact changes for application #{id}: #{e.message}"
  end

  # A secure form submission that replaces a value already on file is marked for staff review.
  def log_medical_provider_changes
    changes = saved_field_changes(MEDICAL_PROVIDER_FIELDS)
    metadata = { changes: changes, changed_by: Current.user&.id }
    source = medical_provider_change_source
    if source.blank?
      AuditEventService.log(action: 'medical_provider_info_updated', actor: Current.user || user, auditable: self, metadata: metadata)
      return
    end

    overwritten_fields = changes.select { |_field, change| change['old'].present? }.keys
    PublicAuditActor.log_audit(
      action: 'medical_provider_info_updated',
      auditable: self,
      metadata: metadata.merge(source).merge(overwritten_fields: overwritten_fields,
                                             review_required: overwritten_fields.any?)
    )
  end

  private

  def medical_provider_change_on_submitted_application?
    MEDICAL_PROVIDER_FIELDS.any? { |field| saved_change_to_attribute?(field) } &&
      attribute_before_last_save(:status) != 'draft'
  end

  def saved_field_changes(fields)
    fields.each_with_object({}) do |field, changes|
      next unless saved_change_to_attribute?(field)

      old_value, new_value = saved_change_to_attribute(field)
      changes[field] = { 'old' => old_value, 'new' => new_value }
    end
  end
end
