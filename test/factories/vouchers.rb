# frozen_string_literal: true

FactoryBot.define do
  factory :voucher do
    code { SecureRandom.alphanumeric(12).upcase }
    initial_value { 500.00 }
    remaining_value { initial_value }
    status { :active }
    issued_at { Time.current }
    application
    vendor

    trait :active do
      status { :active }
    end

    trait :expired do
      status { :expired }
      issued_at { 7.months.ago }
    end

    trait :redeemed do
      status { :redeemed }
      remaining_value { 0 }
    end

    trait :cancelled do
      status { :cancelled }
    end

    trait :with_transactions do
      transient do
        transaction_count { 2 }
      end

      after(:create) do |voucher, evaluator|
        create_list(:voucher_transaction, evaluator.transaction_count,
                    voucher: voucher,
                    vendor: voucher.vendor)
      end
    end
  end
end
