# frozen_string_literal: true

require 'test_helper'

module Admin
  class PoliciesControllerTest < ActionDispatch::IntegrationTest
    def setup
      @admin = create(:admin)
      @policy = Policy.find_or_create_by!(key: 'max_training_sessions') { |p| p.value = 3 }
      sign_in_as(@admin, bypass_mfa_enrollment: true)
    end

    def test_should_get_index
      setup_fpl_policies
      get admin_policies_path
      assert_response :success
      assert_select 'h1', text: 'System Policies'
      modifier = Policy.find_by!(key: 'fpl_modifier_percentage')
      assert_select "form[action='#{bulk_update_admin_policies_path}'][method='post']" do
        assert_select "input[name='_method'][value='patch']"
        assert_select "input[name='policies[][id]'][value=?]", modifier.id.to_s
        assert_select "input[name='policies[][value]'][value='400']"
      end
    end

    test 'the array form bulk update persists both policy values with the signed-in administrator history' do
      setup_fpl_policies
      first = Policy.find_by!(key: 'fpl_1_person')
      second = Policy.find_by!(key: 'fpl_modifier_percentage')
      original = [first.value, second.value]

      assert_difference('PolicyChange.count', 2) do
        patch bulk_update_admin_policies_path, params: {
          policies: [{ id: first.id, value: '16000' }, { id: second.id, value: '500' }]
        }
      end
      assert_redirected_to admin_policies_path
      assert_equal 'Policies updated successfully.', flash[:notice]
      assert_equal [16_000, 500], [first.reload.value, second.reload.value]
      changes = [first, second].map { |policy| policy.policy_changes.order(:id).last }
      assert_equal original, changes.map(&:previous_value)
      assert_equal [16_000, 500], changes.map(&:new_value)
      assert_equal [@admin.id, @admin.id], changes.map(&:user_id)

      get changes_admin_policies_path
      assert_response :success
      assert_select 'td', text: '$16,000.00'
      assert_select 'td', text: '500%'
      assert_select 'td div', text: @admin.full_name
    end

    test 'an invalid keyed bulk update reports refusal and rolls back every changed value and history row' do
      setup_fpl_policies
      first = Policy.find_by!(key: 'fpl_1_person')
      second = Policy.find_by!(key: 'fpl_modifier_percentage')
      original = [first.value, second.value]

      assert_no_difference('PolicyChange.count') do
        patch bulk_update_admin_policies_path, params: {
          policies: {
            first.id.to_s => { id: first.id, value: '16000' },
            second.id.to_s => { id: second.id, value: '' }
          }
        }
      end
      assert_redirected_to admin_policies_path
      assert_match 'Failed to update policies:', flash[:alert]
      assert_equal original, [first.reload.value, second.reload.value]
      follow_redirect!
      assert_select '[data-testid="flash-alert"]', text: /Failed to update policies:/
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

      assert_no_difference ['Policy.count', 'PolicyChange.count'] do
        patch admin_policy_path(@policy), params: { policy: { value: '' } }
      end
      assert_response :unprocessable_content
      assert_select 'h1', text: 'Edit System Policies'
      assert_select '[data-testid="flash-alert"]', text: /Failed to update policy:/
      assert_equal 42, @policy.reload.value
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
      follow_redirect!
      assert_select '[data-testid="flash-notice"]', text: "Policy 'new_test_policy' created successfully.", count: 1

      original = Policy.find_by!(key: 'new_test_policy')
      assert_no_difference ['Policy.count', 'PolicyChange.count'] do
        post admin_policies_path, params: { policy: { key: 'new_test_policy', value: '99' } }
      end
      assert_redirected_to admin_policies_path
      assert_match 'Failed to create policy:', flash[:alert]
      assert_equal 42, original.reload.value
      follow_redirect!
      assert_select '[data-testid="flash-alert"]', text: /Key has already been taken/
    end
  end
end
