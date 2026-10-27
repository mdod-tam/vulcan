# frozen_string_literal: true

module Baseline
  # Checked-in program policy defaults. Every key the application reads with Policy.get belongs here.
  # Values are integers, so text settings such as support_email cannot live in Policy.
  module Policies
    DEFAULTS = {
      'fpl_modifier_percentage' => 400,
      'fpl_1_person' => 15_650,
      'fpl_2_person' => 21_150,
      'fpl_3_person' => 26_650,
      'fpl_4_person' => 32_150,
      'fpl_5_person' => 37_650,
      'fpl_6_person' => 43_150,
      'fpl_7_person' => 48_650,
      'fpl_8_person' => 54_150,
      'max_training_sessions' => 3,
      'waiting_period_years' => 3,
      'proof_submission_rate_limit_web' => 10,
      'proof_submission_rate_limit_email' => 5,
      'proof_submission_rate_period' => 24,
      'sign_in_attempt_rate_limit_ip' => 20,
      'sign_in_attempt_rate_period' => 1,
      'account_access_rate_limit_ip' => 5,
      'account_access_rate_limit_contact_ip' => 5,
      'account_access_rate_limit_user_ip' => 5,
      'account_access_rate_period' => 1,
      'account_recovery_rate_limit_contact_ip' => 5,
      'account_recovery_rate_limit_user_ip' => 3,
      'account_recovery_rate_limit_ip' => 5,
      'account_recovery_rate_period' => 1,
      'max_proof_rejections' => 3,
      'secure_form_link_expiration_hours' => 48,
      'secure_form_resend_cooldown_hours' => 1,
      'voucher_value_hearing_disability' => 500,
      'voucher_value_vision_disability' => 500,
      'voucher_value_speech_disability' => 500,
      'voucher_value_mobility_disability' => 500,
      'voucher_value_cognition_disability' => 500,
      'voucher_validity_period_months' => 6,
      'voucher_minimum_redemption_amount' => 10
    }.freeze

    # Creates missing policies and sets every differing value back to its default through the model,
    # so each change keeps its validation and PolicyChange record.
    def self.reset!(actor:)
      DEFAULTS.each do |key, value|
        policy = Policy.find_or_initialize_by(key: key)
        policy.updated_by = actor
        policy.update!(value: value)
      end
    end
  end
end
