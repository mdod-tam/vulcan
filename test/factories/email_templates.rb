# frozen_string_literal: true

FactoryBot.define do
  factory :email_template do
    sequence(:name) { |n| "template_#{n}" }
    subject { 'Default Subject for %<name>s' }
    body { 'Default body for %<name>s.' }
    variables { 
      { 
        'required' => ['name'], 
        'optional' => [] 
      } 
    }
    description { 'A default email template.' }
    format { :html } # Default format
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

    # Example trait for a specific known template if needed later
    # trait :user_password_reset do
    #   name { 'user_password_reset' }
    #   subject { 'Reset your password' }
    #   body { 'Click here: %<password_reset_url>s' }
    #   variables { ['%<user_first_name>s', '%<password_reset_url>s'] }
    #   description { 'Sent when a user requests a password reset.' }
    # end
  end
end
