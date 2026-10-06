# frozen_string_literal: true

FactoryBot.define do
  factory :medical_provider, class: 'MedicalProvider' do
    sequence(:email) { |n| "doctor#{n}@example.com" }
    password { 'password1234' }
    first_name { 'Dr.' }
    last_name { 'Provider' }
    phone { '555-555-5555' }
    date_of_birth { 40.years.ago }
    timezone { 'Eastern Time (US & Canada)' }
    locale { 'en' }
    email_verified { true }
    verified { true }
    type { 'MedicalProvider' }
  end
end
