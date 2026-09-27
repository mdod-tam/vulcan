# frozen_string_literal: true

module Admin
  # Activity history text for alternate contact and medical provider changes.
  module ContactChangeAuditHelper
    def contact_field_change_label(log)
      case log.action
      when 'alternate_contact_updated'
        'Alternate Contact Updated'
      when 'medical_provider_info_updated'
        log.metadata['review_required'] ? 'Provider Info Replaced - Review' : 'Provider Info Updated'
      end
    end

    # Lists each changed field as "old -> new" so staff can review the change.
    def contact_field_change_detail(log)
      changes = (log.metadata['changes'] || {}).map do |field, change|
        "#{field.to_s.humanize}: #{change['old'].presence || '(blank)'} -> #{change['new'].presence || '(blank)'}"
      end
      detail = changes.join('; ')
      return detail if log.metadata['submitted_via'] != 'secure_request_form'

      overwritten = Array(log.metadata['overwritten_fields']).map(&:humanize)
      source = 'Submitted through a secure provider information link.'
      source = "#{source} Replaced existing #{overwritten.to_sentence} - review this change." if overwritten.any?
      "#{source} #{detail}"
    end
  end
end
