# frozen_string_literal: true

require 'test_helper'

module Admin
  class PoliciesHelperTest < ActionView::TestCase
    include PoliciesHelper

    test 'policy displays distinguish FPL currency modifiers and ordinary values' do
      assert_equal '$15,650.00', format_policy_value('fpl_1_person', 15_650)
      assert_equal '$5,500.00', format_policy_value('fpl_additional_person', 5_500)
      assert_equal '400%', format_policy_value('fpl_modifier_percentage', 400)
      assert_equal '10', format_policy_value('proof_submission_rate_limit_web', 10)
    end

    test 'authentication policy copy covers each live action and scope with explicit time units' do
      AuthRateLimit::ALLOWED_SCOPES_FOR.each do |action, scopes|
        period = system_policy_details("#{action}_rate_period")
        assert_equal 'hours', period[:unit], action.to_s
        assert_match(/first/, period[:description], action.to_s)

        scopes.each do |scope|
          details = system_policy_details("#{action}_rate_limit_#{scope}")
          assert_match(/per time window/, details[:unit], "#{action}/#{scope}")
          assert_no_match(/not documented/, details[:description], "#{action}/#{scope}")
        end
      end

      assert_match(/staff help/, system_policy_details('account_recovery_rate_period')[:description])
      assert_match(/password-reset/, system_policy_details('account_access_rate_period')[:description])
      assert_match(/Successful sign-ins do not count/, system_policy_details('sign_in_attempt_rate_limit_ip')[:description])
      assert_match(/Does not count code-entry attempts/, system_policy_details('sms_verification_rate_limit_contact')[:description])
    end

    test 'unused and unknown saved settings do not invent an active rule or unit' do
      assert_match(/does not affect proof reviews/, system_policy_details('max_proof_rejections')[:description])
      assert_equal 'rejections (not used)', system_policy_details('max_proof_rejections')[:unit]
      details = system_policy_details('unrecognized_saved_setting')
      assert_equal 'unit not documented', details[:unit]
      assert_match(/Confirm its use/, details[:description])
    end
  end
end
