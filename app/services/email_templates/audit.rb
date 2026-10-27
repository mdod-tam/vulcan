# frozen_string_literal: true

module EmailTemplates
  # Read-only preflight: seed files + catalog template aliases vs live DB rows.
  class Audit
    # Derived from EmailDelivery::Catalog.
    ACTION_TEMPLATE_ALIASES = EmailDelivery::Catalog.notification_template_aliases.freeze

    # Templates sent only to staff. They are maintained in English only, so a Spanish row for one is reported
    # but does not block.
    STAFF_ONLY_TEMPLATE_NAMES = %w[
      application_notifications_proof_needs_review_reminder
      application_notifications_training_requested
      evaluator_mailer_new_evaluation_assigned
      training_session_notifications_trainer_assigned
      training_session_notifications_trainer_reassigned
    ].freeze

    def self.run
      new.run
    end

    # Missing or unexpected rows block; staff-only locale rows are informational.
    def self.blocking?(report)
      blocking_findings(report).any?
    end

    def self.blocking_findings(report)
      [*report[:missing_from_db].map { |key| "missing #{key[:name]} (#{key[:locale]}/#{key[:format]})" },
       *report[:unexpected_in_db].map { |tuple| "unexpected #{tuple.join('/')}" }]
    end

    def run
      expected = expected_keys
      db_keys = EmailTemplate.pluck(:name, :locale, :format).map do |name, locale, format|
        [name, locale, normalize_format_key(format)]
      end
      expected_set = expected.to_set { |key| [key[:name], key[:locale], key[:format]] }

      {
        expected_count: expected.size,
        db_count: db_keys.size,
        missing_from_db: expected.reject { |key| db_keys.include?([key[:name], key[:locale], key[:format]]) },
        unexpected_in_db: db_keys.reject { |tuple| expected_set.include?(tuple) },
        staff_only_es_rows: EmailTemplate.where(name: STAFF_ONLY_TEMPLATE_NAMES, locale: 'es').to_a
      }
    end

    private

    def expected_keys
      from_seeds = Catalog.files.map { |path| parse_seed_file(path) }
      (from_seeds + expected_keys_from_mailer_map).uniq { |key| [key[:name], key[:locale], key[:format]] }
    end

    def expected_keys_from_mailer_map
      NotificationService::MAILER_MAP.keys.filter_map do |action|
        template_name = ACTION_TEMPLATE_ALIASES[action]
        next unless template_name

        { name: template_name, locale: 'en', format: 'text' }
      end
    end

    def parse_seed_file(path)
      content = File.read(path)
      name = content[/name:\s*['"]([^'"]+)['"]/, 1] || File.basename(path.to_s, '.rb').sub(/_es\z/, '')
      locale = content[/locale:\s*['"]([^'"]+)['"]/, 1] || (path.to_s.end_with?('_es.rb') ? 'es' : 'en')
      format = content[/format:\s*:(\w+)/, 1] || 'text'
      { name: name, locale: locale, format: format }
    end

    def normalize_format_key(format)
      format.is_a?(Integer) ? EmailTemplate.formats.key(format) : format.to_s
    end
  end
end
