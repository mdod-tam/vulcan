# frozen_string_literal: true

namespace :email_templates do
  desc 'Read-only audit: seed + MAILER_MAP expected keys vs DB'
  task audit: :environment do
    report = EmailTemplates::Audit.run

    puts 'Email template audit'
    puts '=' * 40
    puts "Expected keys: #{report[:expected_count]}"
    puts "DB rows: #{report[:db_count]}"
    puts

    [
      ['Missing from DB', report[:missing_from_db], ->(k) { "#{k[:name]} (#{k[:locale]}/#{k[:format]})" }],
      ['Unexpected in DB', report[:unexpected_in_db], ->(tuple) { tuple.join(' / ') }],
      ['Staff-only templates with es rows', report[:staff_only_es_rows], ->(r) { "#{r.name} (#{r.locale})" }]
    ].each do |title, items, formatter|
      puts title
      if items.empty?
        puts '  (none)'
      else
        items.each { |item| puts "  - #{formatter.call(item)}" }
      end
      puts
    end

    if report[:staff_only_es_rows].any?
      puts 'Note: staff-only es rows are informational until PR 2 copy/locale cleanup (not included in exit status).'
      puts
    end

    blocking_findings = report[:missing_from_db].any? || report[:unexpected_in_db].any?
    puts blocking_findings ? 'Audit finished with findings (exit 1).' : 'Audit finished: OK.'
    exit(1) if blocking_findings
  end
end
