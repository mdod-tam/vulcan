# frozen_string_literal: true

FactoryBot.define do
  factory :equipment_need do
    application { association(:application, :approved, :with_all_proofs, fulfillment_type: :equipment, equipment_needs_initialized_at: Time.current) }
    product
    remaining_quantity { 1 }
    disability_setup_group { 'deaf' }
    unfulfilled_since { Time.current }
  end

  factory :purchase_order do
    sequence(:number) { |n| "PO-#{n}" }
    sent_at { Date.current - 2.days }
  end

  factory :equipment_item do
    application { association(:application, :approved, :with_all_proofs, fulfillment_type: :equipment) }
    product
    disability_setup_group { 'deaf' }
    shipping_address_1 { '123 Main St' }
    shipping_city { 'Baltimore' }
    shipping_state { 'MD' }
    shipping_zip_code { '21201' }
    po_assigned_at { Time.current }
    purchase_order
  end
end
