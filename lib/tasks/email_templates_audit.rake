# frozen_string_literal: true

namespace :email_templates do
  module_function

  def print_audit_section(title, items)
    puts title
    if items.empty?
      puts '  (none)'
    else
      items.each { |item| puts "  - #{yield(item)}" }
    end
    puts
  end

  desc 'Read-only audit: seed + MAILER_MAP expected keys vs DB'
  task audit: :environment do
    report = EmailTemplates::Audit.run

    puts 'Email template audit'
    puts '=' * 40
    puts "Expected keys: #{report[:expected_count]}"
    puts "DB rows: #{report[:db_count]}"
    puts

    print_audit_section('Missing from DB', report[:missing_from_db]) { |k| "#{k[:name]} (#{k[:locale]}/#{k[:format]})" }
    print_audit_section('Unexpected in DB', report[:unexpected_in_db]) { |tuple| tuple.join(' / ') }
    print_audit_section('Staff-only templates with es rows', report[:staff_only_es_rows]) { |r| "#{r.name} (#{r.locale})" }

    findings = report[:missing_from_db].any? || report[:unexpected_in_db].any? || report[:staff_only_es_rows].any?
    puts findings ? 'Audit finished with findings (exit 1).' : 'Audit finished: OK.'
    exit(1) if findings
  end
end
