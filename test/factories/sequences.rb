# frozen_string_literal: true

FactoryBot.define do
  unless FactoryBot.factories.registered?(:email)
    sequence(:email) { |n| "user#{n}@factory.com" } # Use a different domain for factory emails
    sequence(:certifying_professional_name) { |n| "Dr. Jane Smith #{n}" }
    sequence(:certifying_professional_phone) { |n| "123-456-#{n.to_s.rjust(4, '0')}" }
    sequence(:certifying_professional_fax) { |n| "098-765-#{n.to_s.rjust(4, '0')}" }
    sequence(:certifying_professional_email) { |n| "jane.smith#{n}@medicalclinic.com" }
    sequence(:phone) { |n| "555-#{(n % 900) + 100}-#{(n % 9000) + 1000}" }
  end
end
