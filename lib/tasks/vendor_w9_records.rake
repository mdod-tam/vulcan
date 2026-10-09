# frozen_string_literal: true

namespace :vendor_tax_records do
  desc 'Protect existing W9s and invalidate old storage URLs/staged references during paused-write cutover'
  task protect_w9: :environment do
    abort 'Pause application writes and storage cleanup, then set WRITES_PAUSED=1.' unless ENV['WRITES_PAUSED'] == '1'
    abort 'Set CUTOVER_AT to the explicit UTC cutover timestamp.' if ENV['CUTOVER_AT'].blank?

    options = {
      cutover_at: Time.iso8601(ENV.fetch('CUTOVER_AT')),
      after_vendor_id: Integer(ENV.fetch('AFTER_VENDOR_ID', '0')),
      after_staged_blob_id: Integer(ENV.fetch('AFTER_STAGED_BLOB_ID', '0')),
      batch_size: Integer(ENV.fetch('BATCH_SIZE', '100'))
    }
    report = lambda do |cursors|
      puts "AFTER_VENDOR_ID=#{cursors[:after_vendor_id]} AFTER_STAGED_BLOB_ID=#{cursors[:after_staged_blob_id]}"
    end
    cursors = Vendors::W9ProtectionBackfill.call(**options, &report)
    report.call(cursors)
    puts 'W9 protection cutover complete. Purge previously cached W9 responses before restoring access.'
  rescue StandardError => e
    abort "W9 protection cutover stopped (#{e.class}). Resume from the last reported cursors after resolving the failure."
  end
end
