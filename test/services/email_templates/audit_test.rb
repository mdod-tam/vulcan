# frozen_string_literal: true

require 'test_helper'

module EmailTemplates
  class AuditTest < ActiveSupport::TestCase
    test 'expected keys include seed and MAILER_MAP aliases' do
      keys = Audit.new.send(:expected_keys)

      assert(keys.any? { |k| k[:name] == 'application_notifications_account_created' && k[:locale] == 'en' })
      assert(keys.any? { |k| k[:name] == 'application_notifications_proof_rejected' && k[:locale] == 'en' })
    end

    test 'STAFF_ONLY_TEMPLATE_NAMES matches copy-lint staff list' do
      assert_includes Audit::STAFF_ONLY_TEMPLATE_NAMES, 'application_notifications_proof_needs_review_reminder'
      assert_includes Audit::STAFF_ONLY_TEMPLATE_NAMES, 'application_notifications_training_requested'
      assert_includes Audit::STAFF_ONLY_TEMPLATE_NAMES, 'training_session_notifications_trainer_assigned'
      assert_not_includes Audit::STAFF_ONLY_TEMPLATE_NAMES, 'training_session_notifications_training_scheduled'
    end
  end
end
