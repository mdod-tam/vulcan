# frozen_string_literal: true

FactoryBot.define do
  factory :webhook_bounce_payload, class: Hash do
    event { 'bounce' }
    type { 'permanent' }
    email { generate(:email) || 'bounce@example.com' }
    bounce do
      {
        type: 'permanent',
        diagnostics: 'Invalid recipient'
      }
    end

    initialize_with { attributes }

    trait :transient do
      bounce do
        {
          type: 'transient',
          diagnostics: 'Mailbox full'
        }
      end
    end

    trait :suppressed do
      bounce do
        {
          type: 'suppressed',
          diagnostics: 'Email address on suppression list'
        }
      end
    end
  end

  factory :webhook_complaint_payload, class: Hash do
    event { 'complaint' }
    type { 'abuse' }
    email { generate(:email) || 'complaint@example.com' }
    complaint do
      {
        type: 'abuse',
        feedback_id: 'feedback123'
      }
    end

    initialize_with { attributes }

    trait :spam do
      complaint do
        {
          type: 'spam',
          feedback_id: 'spam123'
        }
      end
    end

    trait :virus do
      complaint do
        {
          type: 'virus',
          feedback_id: 'virus123'
        }
      end
    end
  end

  factory :webhook_malformed_payload, class: Hash do
    event { 'bounce' }
    type { 'permanent' }
    email { generate(:email) || 'malformed@example.com' }

    initialize_with { attributes }

    trait :missing_bounce do
      # This empty variant inherits the missing-bounce payload from the base factory.
    end

    trait :invalid_bounce do
      bounce { 'not_a_hash' }
    end

    trait :missing_complaint do
      event { 'complaint' }
    end

    trait :invalid_complaint do
      event { 'complaint' }
      complaint { 'not_a_hash' }
    end

    trait :unknown_event do
      event { 'unknown' }
    end
  end
end
