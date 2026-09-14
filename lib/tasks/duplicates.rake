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

  desc 'Read-only discovery probe for PR 208 architecture correction (optional DETAILED_PII=true)'
  task discovery: :environment do
    detailed = ActiveModel::Type::Boolean.new.cast(ENV.fetch('DETAILED_PII', 'false'))
    probe = DuplicateReconciliation::DiscoveryProbe.new
    result = probe.call(detailed_pii: detailed)
    puts probe.render_summary(result, detailed_pii: detailed)
  end
end
