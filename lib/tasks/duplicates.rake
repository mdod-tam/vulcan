# frozen_string_literal: true

namespace :duplicates do
  desc 'Read-only post-import duplicate pair report (optional CSV_PATH=/path/to/report.csv)'
  task report: :environment do
    result = DuplicateReconciliation::Report.new.call(csv_path: ENV.fetch('CSV_PATH', nil))
    puts "CSV written to #{result.csv_path}" if result.csv_path
  end

  desc 'Synchronize review flags from unresolved post-import pairs and open cases of every source'
  task sync_review_flags: :environment do
    result = DuplicateReconciliation::ReviewFlagSyncService.new.call
    counts = result.data
    puts "Before: #{counts[:before_count]} flagged"
    puts "After: #{counts[:after_count]} flagged"
    puts "Set: #{counts[:set_count]}"
    puts "Cleared: #{counts[:cleared_count]}"
  end
end
