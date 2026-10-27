# frozen_string_literal: true

FactoryBot.define do
  factory :email_template do
    sequence(:name) { |n| "template_#{n}" }
    subject { 'Default Subject for %<name>s' }
    body { 'Default body for %<name>s.' }
    variables do
      {
        'required' => ['name'],
        'optional' => []
      }
    end
    description { 'A default email template.' }
    format { :html }
    locale { 'en' }
    version { 1 }
    enabled { true }
    updated_by factory: %i[admin]

    trait :html do
      format { :html }
      subject { 'HTML Subject for %<name>s' }
      body { '<p>HTML body for %<name>s.</p>' }
    end

    trait :text do
      format { :text }
      subject { 'Text Subject for %<name>s' }
      body { 'Text body for %<name>s.' }
    end
  end
end
