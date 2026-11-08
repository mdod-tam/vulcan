# frozen_string_literal: true

module ProofNotificationCopy
  module_function

  def proof_label(proof_type, locale: I18n.locale)
    normalized = proof_type.to_s.tr('_', ' ').squish
    base_label = normalized.sub(/\s+proof\z/i, '')
    key = base_label.downcase
    key = 'proof' if key.blank?
    labels = I18n.t('notifications.proof_copy.labels', locale: locale)
    return labels.fetch(key.to_sym) if key != 'other' && labels.key?(key.to_sym)

    I18n.t('notifications.proof_copy.labels.other', locale: locale, type: base_label.titleize)
  end

  def attached_text(proof_type, locale: I18n.locale)
    I18n.t('notifications.proof_copy.attached', locale: locale, proof: proof_label(proof_type, locale: locale))
  end

  def approved_text(proof_type, locale: I18n.locale)
    I18n.t('notifications.proof_copy.approved', locale: locale, proof: proof_label(proof_type, locale: locale))
  end

  # For a document that never arrived; rejected_text is for one that was reviewed and found wanting.
  def not_provided_text(proof_type, locale: I18n.locale)
    I18n.t('notifications.proof_copy.not_provided', locale: locale, proof: proof_label(proof_type, locale: locale))
  end

  def rejected_text(proof_type, reason = nil, locale: I18n.locale)
    I18n.t('notifications.proof_copy.rejected', locale: locale, proof: proof_label(proof_type, locale: locale),
                                                reason: rejection_reason_suffix(reason, locale: locale))
  end

  def rejection_reason_suffix(reason, locale: I18n.locale)
    reason.present? ? I18n.t('notifications.proof_copy.reason', locale: locale, reason: reason) : ''
  end

  def requested_text(proof_type, locale: I18n.locale)
    I18n.t('notifications.proof_copy.requested', locale: locale, proof: proof_label(proof_type, locale: locale))
  end
end
