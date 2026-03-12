# frozen_string_literal: true

module Admin
  module RejectionReasonsHelper
    def rejection_reason_body(proof_type:, code:, locale: 'en', fallback: nil, interpolations: {})
      reason = RejectionReason.resolve(code: code, proof_type: proof_type, locale: locale)
      body = reason&.body.presence || fallback.presence || code.to_s.humanize

      interpolate_rejection_reason_body(body, interpolations)
    end

    def rejection_reason_locale_label(locale)
      locale.to_s == 'es' ? 'Spanish (ES)' : 'English (EN)'
    end

    def rejection_reason_proof_type_label(proof_type)
      case proof_type.to_s
      when 'income' then 'Income'
      when 'residency' then 'Residency'
      when 'medical_certification' then 'Medical Certification'
      else proof_type.to_s.humanize
      end
    end

    def rejection_reason_sync_status(reason)
      reason&.needs_sync? ? 'Needs sync' : 'In sync'
    end

    def rejection_reason_sync_badge_classes(reason)
      if reason&.needs_sync?
        'inline-flex items-center rounded-full bg-amber-100 px-3 py-1 text-xs font-medium text-amber-800'
      else
        'inline-flex items-center rounded-full bg-emerald-100 px-3 py-1 text-xs font-medium text-emerald-800'
      end
    end

    def rejection_reason_last_updated_text(reason)
      return 'Last updated: unavailable' unless reason&.updated_at

      editor_name = reason.updated_by&.full_name.presence || 'System'
      formatted_time = reason.updated_at.strftime('%B %d, %Y at %I:%M %p')
      "Last updated (#{reason.locale.to_s.upcase}): #{formatted_time} by #{editor_name}"
    end

    private

    def interpolate_rejection_reason_body(body, interpolations)
      return body if interpolations.blank?
      return body unless body.include?('%{') || body.include?('%<')

      body % interpolations.transform_keys(&:to_sym)
    rescue KeyError, ArgumentError
      body
    end
  end
end
