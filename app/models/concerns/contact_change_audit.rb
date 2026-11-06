# frozen_string_literal: true

# Records old and new values when alternate contact or certifying professional
# fields change, so staff can see what was replaced and by whom.
module ContactChangeAudit
  extend ActiveSupport::Concern

  ALTERNATE_CONTACT_FIELDS = %w[alternate_contact_name alternate_contact_phone alternate_contact_email].freeze
  CERTIFYING_PROFESSIONAL_FIELDS = %w[certifying_professional_name certifying_professional_phone certifying_professional_fax certifying_professional_email].freeze

  included do
    # Audit context for a certifying professional change that comes from a public secure form.
    attr_accessor :certifying_professional_change_source

    # Provider values typed into a draft are not yet on file, so only changes to a
    # submitted application are recorded.
    after_update :log_certifying_professional_changes, if: :certifying_professional_change_on_submitted_application?
    after_save :log_alternate_contact_changes, if: :saved_change_to_alternate_contact?
  end

  def saved_change_to_alternate_contact?
    saved_field_changes(ALTERNATE_CONTACT_FIELDS).any?
  end

  def log_alternate_contact_changes
    changes = saved_field_changes(ALTERNATE_CONTACT_FIELDS)
    return if changes.blank?

    actor = Current.user || PublicAuditActor.system_audit_actor!
    AuditEventService.log(
      action: 'alternate_contact_updated',
      actor: actor,
      auditable: self,
      metadata: { changes: changes, changed_by: actor.id, actor_source: Current.user ? 'explicit' : 'system' }
    )
  end

  # A secure form submission that replaces a value already on file is marked for staff review.
  def log_certifying_professional_changes
    changes = saved_field_changes(CERTIFYING_PROFESSIONAL_FIELDS)
    source = certifying_professional_change_source
    actor = source.present? ? PublicAuditActor.system_audit_actor! : (Current.user || PublicAuditActor.system_audit_actor!)
    metadata = { changes: changes, changed_by: actor.id, actor_source: Current.user ? 'explicit' : 'system' }
    if source.blank?
      AuditEventService.log(action: 'certifying_professional_info_updated', actor: actor, auditable: self, metadata: metadata)
      return
    end

    overwritten_fields = changes.select { |_field, change| change['old'].present? }.keys
    AuditEventService.log(
      actor: actor,
      action: 'certifying_professional_info_updated',
      auditable: self,
      metadata: metadata.merge(source).merge(actor_source: 'public', public_audit_actor: PublicAuditActor::PUBLIC_AUDIT_ACTOR_METADATA,
                                             overwritten_fields: overwritten_fields,
                                             review_required: overwritten_fields.any?)
    )
  end

  private

  def certifying_professional_change_on_submitted_application?
    saved_field_changes(CERTIFYING_PROFESSIONAL_FIELDS).any? &&
      attribute_before_last_save(:status) != 'draft'
  end

  # Only changes staff can see. A form that submits "" for a column holding nil changes nothing on file.
  def saved_field_changes(fields)
    fields.each_with_object({}) do |field, changes|
      next unless saved_change_to_attribute?(field)

      old_value, new_value = saved_change_to_attribute(field)
      next if old_value.blank? && new_value.blank?

      changes[field] = { 'old' => old_value, 'new' => new_value }
    end
  end
end
