# frozen_string_literal: true

FactoryBot.define do
  factory :rejection_reason do
    sequence(:code) { |n| "reason_code_#{n}" }
    proof_type { 'income' }
    locale { 'en' }
    body { 'Sample rejection reason body.' }
    needs_sync { false }
    version { 1 }
  end
end
