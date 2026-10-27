# frozen_string_literal: true

module Admin
  module PrintQueueHelper
    # The three proof-rejection letters share one variant, and the two approval letters share another.
    LETTER_TYPE_VARIANTS = {
      'account_created' => :info,
      'registration_confirmation' => :accent,
      'income_proof_rejected' => :attention,
      'residency_proof_rejected' => :attention,
      'id_proof_rejected' => :attention,
      'income_threshold_exceeded' => :danger,
      'application_approved' => :success,
      'proof_approved' => :success
    }.freeze

    def letter_type_badge_class(letter_type)
      badge_classes(LETTER_TYPE_VARIANTS.fetch(letter_type.to_s, :neutral))
    end
  end
end
