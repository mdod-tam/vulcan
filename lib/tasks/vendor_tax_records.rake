# frozen_string_literal: true

namespace :vendor_tax_records do
  desc 'Check that persistent Active Record encryption keys are configured without printing them'
  task check_keys: :environment do
    keys = Rails.application.credentials.active_record_encryption
    required = %i[primary_key deterministic_key key_derivation_salt]
    abort 'Persistent Active Record encryption credentials are missing; do not encrypt durable tax records.' unless keys && required.all? { |name| keys[name].present? }

    puts 'Persistent Active Record encryption credentials are configured. Confirm the same keys on every application instance and backup.'
  end

  desc 'Encrypt legacy TINs and audit copies; resume with AFTER_USER_ID and AFTER_EVENT_ID'
  task backfill: %i[environment check_keys] do
    options = {
      after_user_id: Integer(ENV.fetch('AFTER_USER_ID', '0')),
      after_event_id: Integer(ENV.fetch('AFTER_EVENT_ID', '0')),
      batch_size: Integer(ENV.fetch('BATCH_SIZE', '100'))
    }
    report = lambda do |cursors|
      puts "AFTER_USER_ID=#{cursors[:after_user_id]} AFTER_EVENT_ID=#{cursors[:after_event_id]}"
    end
    cursors = Vendors::TaxRecordBackfill.call(**options, &report)
    report.call(cursors)
    puts 'Tax record encryption backfill complete.'
  end
end
