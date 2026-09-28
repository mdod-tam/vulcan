# frozen_string_literal: true

FactoryBot.define do
  factory :secure_request_form do
    application
    recipient { application.user }
    requested_by factory: %i[admin]
    kind { :provider_info_request }
    status { :sent }
    request_batch_id { SecureRandom.uuid }
    recipient_email { recipient.email }
    recipient_phone { recipient.phone }
    recipient_channel { :email }
    recipient_role { :constituent }
    delivery_owner { recipient }
    delivery_source { :constituent }
    expires_at { 48.hours.from_now }
    sent_at { Time.current }

    transient do
      raw_token { SecureRequestForm.generate_public_token }
    end

    after(:build) do |secure_request_form, evaluator|
      secure_request_form.public_token_digest = SecureRequestForm.digest_public_token(evaluator.raw_token)
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

    # Sets only the stored channel snapshot. The resolver never chooses SMS by
    # default; SMS needs an explicit override and a text-capable phone.
    trait :sms do
      recipient_channel { :sms }
    end
  end
end
