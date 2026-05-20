# frozen_string_literal: true

FactoryBot.define do
  factory :medical_provider_secure_request_form do
    application
    requested_by factory: %i[admin]
    kind { :certification_upload }
    status { :sent }
    provider_email { application.medical_provider_email }
    provider_name { application.medical_provider_name }
    expires_at { 48.hours.from_now }
    sent_at { Time.current }
    request_batch_id { SecureRandom.uuid }

    transient do
      raw_token { MedicalProviderSecureRequestForm.generate_public_token }
    end

    after(:build) do |secure_request_form, evaluator|
      secure_request_form.public_token_digest = MedicalProviderSecureRequestForm.digest_public_token(evaluator.raw_token)
    end

    trait :expired do
      expires_at { 1.hour.ago }
    end

    trait :submitted do
      status { :submitted }
      submitted_at { Time.current }
    end

    trait :revoked do
      status { :revoked }
      revoked_at { Time.current }
    end
  end
end
