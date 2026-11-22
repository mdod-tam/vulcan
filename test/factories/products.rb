# frozen_string_literal: true

FactoryBot.define do
  factory :product do
    sequence(:name) { |n| "Test Product #{n}" }
    description { 'A detailed description of this assistive technology product.' }
    price { 299.99 }
    manufacturer { 'Assistive Tech Inc.' }
    model_number { "AT-#{SecureRandom.hex(4).upcase}" }
    features { 'High quality, durable, user-friendly interface' }
    compatibility_notes { 'Compatible with most operating systems' }
    documentation_url { 'https://example.com/docs' }
    device_types { ['Tablet'] }
    category { 'devices' }
    eligible_disability_groups { Product::PROGRAM_GROUPS.keys }
    model_confirmed { true }

    trait :archived do
      archived_at { 1.day.ago }
    end

    trait :mobile do
      device_types { ['Smartphone'] }
    end

    trait :tablet do
      device_types { ['Tablet'] }
    end
  end
end
