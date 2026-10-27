# frozen_string_literal: true

module FplPolicyHelpers
  def setup_fpl_policies
    policies = [
      { key: 'fpl_1_person', value: 15_650 },
      { key: 'fpl_2_person', value: 21_150 },
      { key: 'fpl_3_person', value: 26_650 },
      { key: 'fpl_4_person', value: 32_150 },
      { key: 'fpl_5_person', value: 37_650 },
      { key: 'fpl_6_person', value: 43_150 },
      { key: 'fpl_7_person', value: 48_650 },
      { key: 'fpl_8_person', value: 54_150 },
      { key: 'fpl_modifier_percentage', value: 400 },
      { key: 'proof_submission_rate_limit_web', value: 10 },
      { key: 'proof_submission_rate_limit_email', value: 5 },
      { key: 'proof_submission_rate_period', value: 24 },
      { key: 'max_proof_rejections', value: 3 }
    ]

    policies.each do |policy_attrs|
      # Use find_or_create_by to handle race conditions in parallel tests
      Policy.find_or_create_by(key: policy_attrs[:key]) do |policy|
        policy.value = policy_attrs[:value]
      end
    rescue ActiveRecord::RecordNotUnique
      # Handle race condition where another thread created the policy
      # Just update the existing one
      existing_policy = Policy.find_by(key: policy_attrs[:key])
      existing_policy.update!(value: policy_attrs[:value]) if existing_policy && existing_policy.value != policy_attrs[:value]
    end
  end
end
