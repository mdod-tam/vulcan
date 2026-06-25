# frozen_string_literal: true

require 'test_helper'

module EmailTemplates
  class AuditTest < ActiveSupport::TestCase
    test 'expected keys include seed and MAILER_MAP aliases' do
      keys = Audit.new.send(:expected_keys)

      assert(keys.any? { |k| k[:name] == 'application_notifications_account_created' && k[:locale] == 'en' })
      assert(keys.any? { |k| k[:name] == 'application_notifications_proof_rejected' && k[:locale] == 'en' })
    end

    test 'every MAILER_MAP action has an audit alias' do
      missing = NotificationService::MAILER_MAP.keys.reject do |action|
        Audit::ACTION_TEMPLATE_ALIASES.key?(action)
      end

      assert_empty missing, "Missing ACTION_TEMPLATE_ALIASES for: #{missing.join(', ')}"
    end

    test 'STAFF_ONLY_TEMPLATE_NAMES matches planned PR 2 staff-only list' do
      assert_includes Audit::STAFF_ONLY_TEMPLATE_NAMES, 'application_notifications_proof_needs_review_reminder'
      assert_includes Audit::STAFF_ONLY_TEMPLATE_NAMES, 'application_notifications_training_requested'
      assert_includes Audit::STAFF_ONLY_TEMPLATE_NAMES, 'training_session_notifications_trainer_assigned'
      assert_not_includes Audit::STAFF_ONLY_TEMPLATE_NAMES, 'training_session_notifications_training_scheduled'
    end

    test 'expected keys exclude email_template_helper seed file' do
      keys = Audit.new.send(:expected_keys)

      assert(keys.none? { |key| key[:name] == 'email_template_helper' })
    end

    test 'run does not report email_template_helper as missing from DB' do
      report = Audit.run
      missing = report[:missing_from_db].find { |key| key[:name] == 'email_template_helper' }

      assert_nil missing
    end

    test 'run normalizes plucked enum formats as strings for comparison' do
      template = create(:email_template, :text, name: "audit_run_format_#{SecureRandom.hex(4)}")

      report = Audit.run

      unexpected = report[:unexpected_in_db].find { |name, _locale, _format| name == template.name }
      assert_not_nil unexpected
      assert_equal 'text', unexpected[2]
      assert(report[:unexpected_in_db].none? { |_name, _locale, format| format.nil? })
    end

    test 'run does not false-positive missing seeded templates when row exists' do
      seeded_name = 'application_notifications_account_created'
      assert EmailTemplate.exists?(name: seeded_name, locale: 'en', format: :text)

      report = Audit.run
      missing = report[:missing_from_db].find do |key|
        key[:name] == seeded_name && key[:locale] == 'en' && key[:format] == 'text'
      end

      assert_nil missing
    end
  end
end
