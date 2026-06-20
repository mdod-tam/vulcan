# frozen_string_literal: true

module EmailTemplates
  # Read-only preflight: seed files + MAILER_MAP aliases vs live DB rows.
  class Audit
    SEED_DIR = Rails.root.join('db/seeds/email_templates').freeze
    EXCLUDED_SEED_FILES = %w[email_template_helper.rb].freeze

    ACTION_TEMPLATE_ALIASES = {
      'proof_rejected' => 'application_notifications_proof_rejected',
      'id_proof_rejected' => 'application_notifications_proof_rejected',
      'income_proof_rejected' => 'application_notifications_proof_rejected',
      'residency_proof_rejected' => 'application_notifications_proof_rejected',
      'id_proof_attached' => 'application_notifications_proof_received',
      'income_proof_attached' => 'application_notifications_proof_received',
      'residency_proof_attached' => 'application_notifications_proof_received',
      'account_created' => 'application_notifications_account_created',
      'w9_approved' => 'vendor_notifications_w9_approved',
      'w9_rejected' => 'vendor_notifications_w9_rejected',
      'training_requested' => 'application_notifications_training_requested',
      'trainer_assigned' => 'training_session_notifications_trainer_assigned',
      'training_scheduled' => 'training_session_notifications_training_scheduled',
      'training_rescheduled' => 'training_session_notifications_training_rescheduled',
      'training_cancelled' => 'training_session_notifications_training_cancelled',
      'training_missed' => 'training_session_notifications_training_no_show',
      'security_key_recovery_approved' => 'application_notifications_security_key_recovery_approved',
      'medical_certification_requested' => 'medical_provider_request_certification',
      'medical_certification_not_provided' => 'application_notifications_medical_certification_not_provided',
      'max_rejections_warning' => 'application_notifications_max_rejections_reached'
    }.freeze

    # Kept aligned with the planned PR 2 staff-only template copy/lint list.
    STAFF_ONLY_TEMPLATE_NAMES = %w[
      application_notifications_proof_needs_review_reminder
      application_notifications_training_requested
      evaluator_mailer_new_evaluation_assigned
      training_session_notifications_trainer_assigned
    ].freeze

    def self.run
      new.run
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
      from_seeds = seed_files.flat_map { |path| parse_seed_file(path) }
      from_mailer = expected_keys_from_mailer_map
      (from_seeds + from_mailer).uniq { |key| [key[:name], key[:locale], key[:format]] }
    end

    def seed_files
      Dir.glob(SEED_DIR.join('*.rb')).reject do |path|
        EXCLUDED_SEED_FILES.include?(File.basename(path))
      end
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
      name = content[/name:\s*['"]([^'"]+)['"]/, 1] || File.basename(path, '.rb').sub(/_es\z/, '')
      locale = content[/locale:\s*['"]([^'"]+)['"]/, 1] || (path.end_with?('_es.rb') ? 'es' : 'en')
      format = content[/format:\s*:(\w+)/, 1] || 'text'
      [{ name: name, locale: locale, format: format }]
    end

    def normalize_format_key(format)
      format.is_a?(Integer) ? EmailTemplate.formats.key(format) : format.to_s
    end
  end
end
