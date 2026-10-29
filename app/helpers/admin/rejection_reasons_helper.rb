# frozen_string_literal: true

module Admin
  module RejectionReasonsHelper
    def rejection_reason_locale_label(locale)
      locale.to_s == 'es' ? 'Spanish (ES)' : 'English (EN)'
    end

    def rejection_reason_proof_type_label(proof_type)
      case proof_type.to_s
      when 'income' then 'Income'
      when 'residency' then 'Residency'
      when 'disability_certification' then 'Disability Certification'
      else proof_type.to_s.humanize
      end
    end

    def rejection_reason_sync_status(reason)
      reason&.needs_sync? ? 'Needs sync' : 'In sync'
    end

    def rejection_reason_sync_badge_classes(reason)
      badge_classes(reason&.needs_sync? ? :warning : :success)
    end

    def rejection_reason_last_updated_text(reason)
      return 'Last updated: unavailable' unless reason&.updated_at

      editor_name = reason.updated_by&.full_name.presence || 'System'
      formatted_time = reason.updated_at.strftime('%B %d, %Y at %I:%M %p')
      "Last updated (#{reason.locale.to_s.upcase}): #{formatted_time} by #{editor_name}"
    end
  end
end
