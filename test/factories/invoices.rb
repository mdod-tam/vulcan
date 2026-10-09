# frozen_string_literal: true

FactoryBot.define do
  factory :invoice do
    sequence(:invoice_number) { |n| "INV-#{Time.current.strftime('%Y%m')}-#{n.to_s.rjust(4, '0')}" } # Use sequence for uniqueness
    vendor factory: %i[vendor]
    sequence(:start_date) { |n| (5 - n).weeks.ago.beginning_of_day } # Use sequence for non-overlapping weekly dates
    sequence(:end_date) { |n| (5 - n).weeks.ago.end_of_day + 6.days } # Use sequence for non-overlapping weekly dates
    status { :invoice_pending }
    total_amount { 0 }

    trait :pending do
      status { :invoice_pending }
    end

    trait :approved do
      status { :invoice_approved }
      approved_at { Time.current }
    end

    trait :paid do
      status { :invoice_paid }
      approved_at { 1.day.ago }
      payment_recorded_at { Time.current }
      gad_invoice_reference { "GAD-#{SecureRandom.hex(6).upcase}" }
      check_number { "CHK#{SecureRandom.hex(4).upcase}" } # Optional
    end

    trait :cancelled do
      status { :invoice_cancelled }
    end

    trait :with_transactions do
      transient do
        transaction_count { 3 }
        amount_per_transaction { 100.00 }
      end

      after(:create) do |invoice, evaluator|
        transactions = create_list(:voucher_transaction, evaluator.transaction_count,
                                   vendor: invoice.vendor,
                                   amount: evaluator.amount_per_transaction,
                                   invoice: invoice,
                                   status: :transaction_completed)

        # The factory builds an already-issued record, so it sets the total directly, as an import would;
        # approved and paid invoices otherwise refuse a changed total.
        invoice.update_column(:total_amount, transactions.sum(&:amount))
      end
    end

    trait :current_period do
      start_date { 2.weeks.ago.beginning_of_day }
      end_date { Time.current.end_of_day }
    end

    trait :previous_period do
      start_date { 4.weeks.ago.beginning_of_day }
      end_date { 2.weeks.ago.end_of_day }
    end

    trait :with_notes do
      notes { 'Payment processed via direct deposit' }
    end

    # Ensure total amount matches transactions
    after(:create) do |invoice|
      actual_total = invoice.voucher_transactions.sum(:amount)
      invoice.update_column(:total_amount, actual_total) if invoice.total_amount != actual_total
    end
  end
end
