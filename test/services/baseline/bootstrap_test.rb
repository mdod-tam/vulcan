# frozen_string_literal: true

require 'test_helper'

module Baseline
  class BootstrapTest < ActiveSupport::TestCase
    include ActionMailer::TestHelper

    ENVIRONMENT = {
      'BOOTSTRAP_ADMIN_EMAIL' => 'Bootstrap.Admin@Example.test', 'BOOTSTRAP_ADMIN_FIRST_NAME' => 'Boot',
      'BOOTSTRAP_ADMIN_LAST_NAME' => 'Strap', 'BOOTSTRAP_ADMIN_PASSWORD' => 'Correct-Horse-Battery-9!'
    }.freeze

    setup do
      @input = Bootstrap.administrator_input(ENVIRONMENT)
      @output = StringIO.new
    end

    test 'administrator input names each missing variable without printing a value' do
      error = assert_raises(Bootstrap::ConfigurationError) do
        Bootstrap.administrator_input(ENVIRONMENT.except('BOOTSTRAP_ADMIN_PASSWORD').merge('BOOTSTRAP_ADMIN_FIRST_NAME' => ' '))
      end

      assert_includes error.message, 'BOOTSTRAP_ADMIN_FIRST_NAME'
      assert_includes error.message, 'BOOTSTRAP_ADMIN_PASSWORD'
      assert_not_includes error.message, ENVIRONMENT['BOOTSTRAP_ADMIN_EMAIL']
    end

    test 'the administrator must be separate from the system audit account' do
      assert_raises(Bootstrap::ConfigurationError) do
        Bootstrap.administrator_input(ENVIRONMENT.merge('BOOTSTRAP_ADMIN_EMAIL' => PublicAuditActor::SYSTEM_AUDIT_EMAIL.upcase))
      end
    end

    test 'run provisions the accounts and baseline, verifies them, and prints no secret or address' do
      assert_no_emails do
        Bootstrap.run!(input: @input, out: @output)
      end

      admin = User.admins.find_by!(email: 'bootstrap.admin@example.test')
      assert admin.authenticate(ENVIRONMENT['BOOTSTRAP_ADMIN_PASSWORD'])
      assert_equal [0, 0, 0], [admin.totp_credentials.count, admin.webauthn_credentials.count, admin.sms_credentials.count]
      assert_includes @output.string, 'Bootstrap complete'
      [ENVIRONMENT['BOOTSTRAP_ADMIN_PASSWORD'], 'bootstrap.admin@example.test'].each do |secret|
        assert_not_includes @output.string.downcase, secret.downcase
      end
    end

    test 'a second run keeps the accounts as they were and restores edited baseline data' do
      Bootstrap.run!(input: @input, out: @output)
      admin = User.admins.find_by!(email: 'bootstrap.admin@example.test')
      admin.update!(first_name: 'Renamed')
      snapshot = admin.reload.attributes
      Policy.find_by!(key: 'max_proof_rejections').update_columns(value: 9)
      FeatureFlag.find_by!(name: 'vouchers_enabled').update_columns(enabled: true)
      EmailTemplate.first.update_columns(body: 'Edited copy')
      RejectionReason.first.update_columns(body: 'Edited reason')

      assert_no_difference ['User.count', 'Policy.count', 'FeatureFlag.count', 'RejectionReason.count', 'EmailTemplate.count'] do
        Bootstrap.run!(input: Bootstrap.administrator_input(ENVIRONMENT.merge('BOOTSTRAP_ADMIN_PASSWORD' => 'A-different-password-1')),
                       out: @output)
      end

      assert_equal snapshot, admin.reload.attributes
      assert admin.authenticate(ENVIRONMENT['BOOTSTRAP_ADMIN_PASSWORD'])
      assert_equal 3, Policy.get('max_proof_rejections')
      assert_not FeatureFlag.enabled?(:vouchers_enabled)
      assert_not_includes EmailTemplate.pluck(:body), 'Edited copy'
      assert_not_includes RejectionReason.pluck(:body), 'Edited reason'
    end

    test 'a failure before commit restores the previous accounts, policies, and catalog' do
      Policy.find_by!(key: 'max_proof_rejections').update_columns(value: 9)
      templates = EmailTemplate.order(:id).pluck(:id, :body)
      RejectionReasons.stubs(:reset!).raises(ActiveRecord::StatementInvalid, 'injected failure')

      assert_no_difference 'User.count' do
        assert_raises(ActiveRecord::StatementInvalid) { Bootstrap.run!(input: @input, out: @output) }
      end

      assert_equal 9, Policy.get('max_proof_rejections')
      assert_equal templates, EmailTemplate.order(:id).pluck(:id, :body)
      assert_empty @output.string
    end

    test 'a readback failure after commit is reported as committed, not rolled back' do
      Bootstrap.stubs(:verify!).returns(nil).then.raises(Bootstrap::VerificationError, 'injected readback failure')

      error = assert_raises(Bootstrap::CommittedError) { Bootstrap.run!(input: @input, out: @output) }

      assert_match(/committed.*not rolled back/i, error.message)
      assert User.admins.exists?(email: 'bootstrap.admin@example.test')
    end

    test 'verification reports every baseline problem it finds' do
      Policy.find_by!(key: 'max_proof_rejections').update_columns(value: 9)
      EmailTemplate.find_by!(name: 'user_mailer_password_reset').destroy!

      error = assert_raises(Bootstrap::VerificationError) { Bootstrap.verify!(@input) }

      assert_match(/administrator is missing.*policy values differ.*missing user_mailer_password_reset/m, error.message)
    end
  end
end
