# frozen_string_literal: true

FactoryBot.define do
  factory :policy do
    sequence(:key) { |n| "policy_key_#{n}" }
    value { 50 }

    trait :rate_limit do
      sequence(:key) { |n| "proof_submission_rate_limit_web_#{n}" }
      value { 10 }
    end

    trait :voucher do
      sequence(:key) { |n| "voucher_value_hearing_disability_#{n}" }
      value { 500 }
    end

    trait :proof_submission_rate_limit_web do
      key { 'proof_submission_rate_limit_web' }
      value { 10 } # Allow 10 submissions via web
    end

    trait :proof_submission_rate_limit_email do
      key { 'proof_submission_rate_limit_email' }
      value { 5 } # Allow 5 submissions via email
    end

    trait :proof_submission_rate_period do
      key { 'proof_submission_rate_period' }
      value { 24 } # Period of 24 hours
    end

    trait :max_proof_rejections do
      key { 'max_proof_rejections' }
      value { 3 } # Maximum of 3 rejections allowed
    end
  end
end

# Helper method to clean up test policies - defined outside the factory
def cleanup_test_policies
  Policy.where("key LIKE 'policy_key_%' OR key LIKE '%_test_%'").delete_all
end
