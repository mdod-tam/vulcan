# frozen_string_literal: true

FactoryBot.define do
  factory :print_queue_item do
    letter_type { :income_proof_rejected }
    status { :printed }

    # Create unique users to avoid email/phone conflicts
    constituent do
      unique_id = SecureRandom.hex(6)
      # 10-digit phone number starting with 555.
      phone_suffix = (unique_id.to_i(16) % 10_000_000).to_s.rjust(7, '0')
      create(:constituent,
             email: "pqi_constituent_#{unique_id}@example.com",
             phone: "555#{phone_suffix}")
    end

    application do
      unique_id = SecureRandom.hex(6)
      # 10-digit phone number starting with 555.
      phone_suffix = (unique_id.to_i(16) % 10_000_000).to_s.rjust(7, '0')
      create(:application,
             user: create(:constituent,
                          email: "pqi_app_user_#{unique_id}@example.com",
                          phone: "555#{phone_suffix}"))
    end

    admin do
      unique_id = SecureRandom.hex(6)
      # 10-digit phone number starting with 555.
      phone_suffix = (unique_id.to_i(16) % 10_000_000).to_s.rjust(7, '0')
      create(:admin,
             email: "pqi_admin_#{unique_id}@example.com",
             phone: "555#{phone_suffix}")
    end

    printed_at { Time.current }

    after(:build) do |print_queue_item|
      # Attach a sample PDF file for the pdf_letter requirement
      print_queue_item.pdf_letter.attach(
        io: Rails.root.join('test/fixtures/files/sample.pdf').open,
        filename: 'sample_letter.pdf',
        content_type: 'application/pdf'
      )
    end

    trait :pending do
      status { :pending }
      printed_at { nil }
      admin { nil }
    end

    trait :canceled do
      status { :canceled }
      printed_at { nil }
    end

    trait :account_created do
      letter_type { :account_created }
    end

    trait :application_approved do
      letter_type { :application_approved }
    end
  end
end
