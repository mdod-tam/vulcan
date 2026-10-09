# frozen_string_literal: true

FactoryBot.define do
  factory :w9_review do
    vendor
    admin
    status { :approved }
    reviewed_at { Time.current }
    reviewed_blob { vendor.w9_form.blob }

    trait :approved do
      status { :approved }
    end

    trait :rejected do
      status { :rejected }
      rejection_reason_code { :address_mismatch }
      rejection_reason { 'The address on the W9 form does not match the business address.' }
    end
  end
end
