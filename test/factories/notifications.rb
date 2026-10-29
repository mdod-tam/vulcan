# frozen_string_literal: true

FactoryBot.define do
  unless FactoryBot.factories.registered?(:notification)
    factory :notification do
      recipient factory: %i[user]
      actor factory: %i[user]
      notifiable factory: %i[application]

      action { 'proof_submitted' }
      read_at { nil }
      metadata do
        {
          proof_types: ['income'],
          application_id: nil
        }
      end

      trait :read do
        read_at { Time.current }
      end

      trait :proof_rejected do
        action { 'proof_rejected' }
        metadata do
          {
            proof_types: ['income'],
            rejection_reason: 'Document unclear'
          }
        end
      end

      trait :bounced_email do
        action { 'certifying_professional_email_bounced' }
        metadata do
          {
            email: 'doctor@example.com',
            bounce_type: 'permanent',
            diagnostics: 'Invalid recipient'
          }
        end
      end

      after(:create) do |notification|
        if notification.notifiable.is_a?(Application) && notification.metadata['application_id'].nil?
          notification.update!(
            metadata: notification.metadata.merge(
              'application_id' => notification.notifiable.id
            )
          )
        end
      end
    end
  end
end
