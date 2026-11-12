# frozen_string_literal: true

require 'test_helper'

module Admin
  class PoliciesHelperTest < ActionView::TestCase
    include PoliciesHelper

    test 'policy displays distinguish FPL currency modifiers and ordinary values' do
      assert_equal '$15,650.00', format_policy_value('fpl_1_person', 15_650)
      assert_equal '400%', format_policy_value('fpl_modifier_percentage', 400)
      assert_equal '10', format_policy_value('proof_submission_rate_limit_web', 10)
    end
  end
end
