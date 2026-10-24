# frozen_string_literal: true

require_relative '../support/document_scan_fixtures' if Rails.env.test?

FactoryBot.define do
  factory :vendor, parent: :user, class: 'Users::Vendor' do
    type { 'Users::Vendor' }
    sequence(:email) { |n| "vendor#{n}@example.com" }
    sequence(:phone) { |n| "444-#{format('%03d', (n % 900) + 100)}-#{format('%04d', (n % 9000) + 1000)}" }
    first_name { 'Test' }
    last_name { 'Vendor' }
    sequence(:business_name) { |n| "Test Business #{n}" }
    sequence(:business_tax_id) { |n| "12345#{n.to_s.rjust(4, '0')}" }
    vendor_authorization_status { :pending }
    status { :active } # Ensure vendors can authenticate by default

    trait :approved do
      vendor_authorization_status { :approved }
      status { :active } # Ensure vendor can authenticate
      sequence(:business_name) { |n| "Approved Vendor #{n}" }
      sequence(:business_tax_id) { |n| "99-#{n.to_s.rjust(7, '0')}" }
      terms_accepted_at { 1.day.ago }
      after(:create) do |vendor|
        vendor.w9_form.attach(
          io: Rails.root.join('test/fixtures/files/sample_w9.pdf').open,
          filename: 'w9.pdf',
          content_type: 'application/pdf'
        )
        if Rails.env.test?
          DocumentScanFixtures.clear!(vendor.w9_form.blob, user: vendor,
                                                           purpose: :w9, slot: 'w9_form',
                                                           fixture: 'sample_w9.pdf')
        end
        # Set w9_status to approved after file attachment to override callback
        vendor.update_column(:w9_status, :approved)
      end
    end

    trait :pending do
      vendor_authorization_status { :pending }
    end

    trait :suspended do
      vendor_authorization_status { :suspended }
    end

    trait :with_w9 do
      after(:create) do |vendor|
        vendor.w9_form.attach(
          io: Rails.root.join('test/fixtures/files/sample_w9.pdf').open,
          filename: 'w9.pdf',
          content_type: 'application/pdf'
        )
        if Rails.env.test?
          DocumentScanFixtures.clear!(vendor.w9_form.blob, user: vendor,
                                                           purpose: :w9, slot: 'w9_form',
                                                           fixture: 'sample_w9.pdf')
        end
        vendor.update(w9_status: :pending_review)
      end
    end

    trait :with_transactions do
      transient do
        transaction_count { 3 }
      end

      after(:create) do |vendor, evaluator|
        create_list(:voucher_transaction, evaluator.transaction_count,
                    vendor: vendor,
                    status: :transaction_completed)
      end
    end

    trait :with_pending_invoice do
      after(:create) do |vendor|
        create(:invoice, :with_transactions,
               vendor: vendor,
               status: :invoice_pending)
      end
    end

    trait :with_paid_invoice do
      after(:create) do |vendor|
        create(:invoice, :with_transactions,
               vendor: vendor,
               status: :invoice_paid,
               paid_at: Time.current)
      end
    end

    trait :with_terms_accepted do
      terms_accepted_at { 1.day.ago }
    end

    trait :with_full_profile do
      business_name { 'Complete Business' }
      business_tax_id { '123456789' }
      phone { '555-123-4567' }
      terms_accepted_at { 1.day.ago }
      after(:create) do |vendor|
        vendor.w9_form.attach(
          io: Rails.root.join('test/fixtures/files/sample_w9.pdf').open,
          filename: 'w9.pdf',
          content_type: 'application/pdf'
        )
        if Rails.env.test?
          DocumentScanFixtures.clear!(vendor.w9_form.blob, user: vendor,
                                                           purpose: :w9, slot: 'w9_form',
                                                           fixture: 'sample_w9.pdf')
        end
      end
    end
  end
end
