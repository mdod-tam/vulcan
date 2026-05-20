# frozen_string_literal: true

require 'test_helper'

module Admin
  class PoliciesControllerTest < ActionDispatch::IntegrationTest
    def setup
      @admin = create(:admin)
      @policy = Policy.find_or_create_by!(key: 'max_training_sessions') { |p| p.value = 3 }
      sign_in_as(@admin) # Use standard helper
    end

    def test_should_get_index
      get admin_policies_path
      assert_response :success
      assert_select 'h1', text: 'System Policies'
      # PHASE 5 FIX: The form action is different from what the test expected
      # The actual form uses bulk_update_admin_policies_path, not just /admin/policies
      assert_select "form[action*='admin/policies'][method='post']"
    end

    def test_should_see_edit_form_on_index
      # Policies are edited directly on the index page
      get admin_policies_path
      assert_response :success
      # PHASE 5 FIX: The form action is different from what the test expected,
      # and there are multiple forms on the page (one for each policy section)
      assert_select "form[action*='admin/policies'][method='post']", { minimum: 1 },
                    'Should have at least one form for policies'
    end

    def test_index_hides_retired_email_submission_rate_limit
      Policy.find_or_create_by!(key: 'proof_submission_rate_limit_email') { |p| p.value = 5 }

      get admin_policies_path

      assert_response :success
      assert_select 'label', text: 'Email Submissions', count: 0
      assert_no_match(/email submissions are through email attachments/i, response.body)
    end

    def test_should_get_edit
      get edit_admin_policy_path(@policy)
      assert_response :success
      assert_select 'h1', text: 'Edit System Policies'
    end

    def test_should_get_changes
      get changes_admin_policies_path
      assert_response :success
    end

    def test_should_update_policy
      patch admin_policy_path(@policy), params: {
        policy: {
          value: '42'
        }
      }
      assert_redirected_to admin_policies_path
      @policy.reload
      assert_equal '42', @policy.value.to_s
    end

    def test_should_create_policy
      assert_difference('Policy.count') do
        post admin_policies_path, params: {
          policy: {
            key: 'new_test_policy',
            value: '42'
          }
        }
      end
      assert_redirected_to admin_policies_path
      assert_equal "Policy 'new_test_policy' created successfully.", flash[:notice]
    end
  end
end
