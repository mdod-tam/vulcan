# frozen_string_literal: true

module ProofNotificationCopy
  module_function

  def proof_label(proof_type)
    return 'Proof' if proof_type.blank?

    normalized = proof_type.to_s.tr('_', ' ').squish
    return 'Proof' if normalized.casecmp('proof').zero?

    base_label = normalized.sub(/\s+proof\z/i, '')
    formatted = base_label.casecmp('id').zero? ? 'ID' : base_label.titleize

    "#{formatted} proof"
  end

  def attached_text(proof_type)
    "#{proof_label(proof_type)} attached"
  end

  def approved_text(proof_type)
    "#{proof_label(proof_type)} approved"
  end

  def rejected_text(proof_type, reason = nil)
    "#{proof_label(proof_type)} rejected#{rejection_reason_suffix(reason)}"
  end

  def rejection_reason_suffix(reason)
    reason.present? ? " - #{reason}" : ''
  end

  def requested_text(proof_type)
    "#{proof_label(proof_type)} requested"
  end
end
