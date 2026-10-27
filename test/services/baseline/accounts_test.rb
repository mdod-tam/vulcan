# frozen_string_literal: true

require 'test_helper'

module Baseline
  class AccountsTest < ActiveSupport::TestCase
    include ActionMailer::TestHelper

    INPUT = { first_name: 'First', last_name: 'Admin', password: 'Correct-Horse-Battery-9!' }.freeze

    test 'a new administrator is normalized, verified by email, and given no factors, sessions, or messages' do
      assert_no_emails do
        assert_no_difference ['Notification.count', 'Session.count', 'TotpCredential.count', 'WebauthnCredential.count', 'SmsCredential.count'] do
          admin = Accounts.provision_administrator!(email: ' New.Admin@Example.test ', **INPUT)

          assert_instance_of Users::Administrator, admin
          assert_equal 'new.admin@example.test', admin.email
          assert admin.email_verified
          assert admin.authenticate(INPUT[:password])
        end
      end
    end

    test 'an existing eligible administrator is returned exactly as it is' do
      existing = create(:admin, password: 'password1234', first_name: 'Original')
      snapshot = existing.reload.attributes

      result = Accounts.provision_administrator!(email: existing.email.upcase, first_name: 'Changed', last_name: 'Changed',
                                                 password: 'Another-password-1')

      assert_equal existing.id, result.id
      assert_equal snapshot, result.reload.attributes
      assert result.authenticate('password1234')
    end

    test 'the already provisioned system audit actor is left unchanged' do
      actor = ensure_system_audit_actor!
      snapshot = actor.attributes

      assert_no_difference 'User.count' do
        assert_equal snapshot, Accounts.provision_system_audit_actor!.attributes
      end
    end

    test 'every conflicting identity is refused without promotion, reactivation, or changes' do
      conflicts = {
        'constituent' => create(:constituent),
        'inactive administrator' => create(:admin, status: :inactive),
        'suspended administrator' => create(:admin, status: :suspended),
        'merged administrator' => create(:admin, merged_into_user_id: create(:admin).id),
        'legacy STI administrator' => create(:admin).tap { |user| user.update_columns(type: 'Users::LegacyAdmin') }
      }

      conflicts.each do |name, user|
        snapshot = User.where(id: user.id).pick(:type, :status, :merged_into_user_id)

        assert_no_difference 'User.count' do
          assert_raises(Accounts::Conflict, name) do
            Accounts.provision_administrator!(email: user.email, **INPUT)
          end
        end
        assert_equal snapshot, User.where(id: user.id).pick(:type, :status, :merged_into_user_id), name
      end
    end

    test 'a database error during the lookup is not read as no such user' do
      User.stubs(:where).raises(ActiveRecord::StatementInvalid, 'lookup failed')

      assert_no_difference 'User.count' do
        assert_raises(ActiveRecord::StatementInvalid) { Accounts.provision_administrator!(email: 'x@example.test', **INPUT) }
      end
    end
  end
end
