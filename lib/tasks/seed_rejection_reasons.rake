# frozen_string_literal: true

namespace :db do
  desc 'Seed RejectionReason records for production (does not require FactoryBot)'
  task seed_rejection_reasons: :environment do
    puts "=== Rejection Reason Seeding START at #{Time.current} ==="

    before_count = RejectionReason.count
    load Rails.root.join('db/seeds/rejection_reasons.rb')
    seed_rejection_reasons

    created = RejectionReason.count - before_count
    puts "Rejection reasons: #{before_count} → #{RejectionReason.count} (#{created} created)"
    puts "=== Rejection Reason Seeding END at #{Time.current} ==="
  rescue StandardError => e
    puts "❌ Error seeding rejection reasons: #{e.message}"
    puts e.backtrace.first(5)
    raise
  end
end
