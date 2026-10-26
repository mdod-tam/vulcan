# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class PoliciesTest < ApplicationSystemTestCase
    def setup
      @admin = create(:admin)

      @policy = Policy.find_or_create_by!(key: 'max_training_sessions') do |p|
        p.value = 3
      end

      setup_fpl_policies

      system_test_sign_in(@admin)
    end

    test 'should display policies page' do
      visit admin_policies_path
      wait_for_turbo

      assert_selector 'h1', text: 'System Policies'

      assert_text 'Federal Poverty Level (FPL) Settings'
    end

    test 'should display policy change history' do
      visit changes_admin_policies_path
      wait_for_turbo

      assert_selector 'h1', text: 'Policy Change History'
      assert_no_text 'Content missing'

      assert_link 'Back to Policies'
    end
  end
end
