# frozen_string_literal: true

FactoryBot.define do
  factory :equipment_need do
    application { association(:application, :approved, :with_all_proofs, fulfillment_type: :equipment, equipment_needs_initialized_at: Time.current) }
    product
    remaining_quantity { 1 }
  end

  factory :purchase_order do
    vendor
    sequence(:number) { |n| "PO-#{n}" }
    sent_at { Date.current - 2.days }
  end

  factory :equipment_item do
    application { association(:application, :approved, :with_all_proofs, fulfillment_type: :equipment) }
    product
    purchase_order
  end
end
