# frozen_string_literal: true

FactoryBot.define do
  # The default is the grant the policy allows: an evaluator granted training. Pass user: for the other direction.
  factory :role_capability do
    user factory: %i[evaluator]
    capability { 'can_train' }
  end
end
