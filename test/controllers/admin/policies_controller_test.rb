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
      assert_policy_editor('System Policies')
      modifier = Policy.find_by!(key: 'fpl_modifier_percentage')
      assert_select "form[action='#{bulk_update_admin_policies_path}'][method='post']" do
        assert_select "input[name='_method'][value='patch']"
        assert_select "input[name='policies[][id]'][value=?]", modifier.id.to_s
        assert_select "input[name='policies[][value]'][value='400']"
      end
    end

    test 'other system policy inputs describe their purpose and units without changing their values' do
      defaults = Baseline::Policies::DEFAULTS.reject { |key, _| key.start_with?('fpl_', 'proof_submission_rate_', 'voucher_') }
      AuthRateLimit::ALLOWED_SCOPES_FOR.each do |action, scopes|
        defaults["#{action}_rate_period"] ||= AuthRateLimit::DEFAULT_PERIOD_HOURS
        scopes.each { |scope| defaults["#{action}_rate_limit_#{scope}"] ||= AuthRateLimit.default_max(action, scope) }
      end
      policies = defaults.map { |key, value| Policy.find_or_create_by!(key: key) { |policy| policy.value = value } }
      saved_values = policies.to_h { |policy| [policy.id, policy.value] }

      get admin_policies_path
      assert_response :success
      policies.each do |policy|
        input = css_select("input#policies_#{policy.id}_value").sole
        assert_equal 'policies[][value]', input['name']
        assert_equal saved_values.fetch(policy.id).to_s, input['value']
        assert_equal '0', input['min']
        assert_not_nil input['required']
        assert_select "label[for='#{input['id']}']", count: 1
        assert_equal ["policy_#{policy.id}_description", "policy_#{policy.id}_unit"], input['aria-describedby'].split
        input['aria-describedby'].split.each do |id|
          assert_select "##{id}", count: 1
          assert_not_empty css_select("##{id}").sole.text.strip
        end
        assert_no_match(/not documented/, css_select("#policy_#{policy.id}_description").sole.text)
        assert_select "input[name='policies[][id]'][value='#{policy.id}']", count: 1
      end
      recovery = policies.find { |policy| policy.key == 'account_recovery_rate_period' }
      assert_select "label[for='policies_#{recovery.id}_value']", text: 'Account recovery time window'
      assert_select "#policy_#{recovery.id}_unit", text: 'hours'
      assert_select "#policy_#{recovery.id}_description", text: /staff help recovering security-key access/
      assert_select 'label', text: /Proof submission rate limit email/, count: 0
      current_values = policies.to_h { |policy| [policy.id, policy.reload.value] }
      assert_equal saved_values, current_values
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
      assert_policy_editor('Edit System Policies')
    end

    test 'missing policy creation forms keep their original defaults outside the bulk editor' do
      setup_fpl_policies
      defaults = {
        'fpl_2_person' => Baseline::Policies::DEFAULTS.fetch('fpl_2_person'),
        'fpl_additional_person' => Baseline::Policies::DEFAULTS.fetch('fpl_additional_person'),
        'proof_submission_rate_period' => 1, 'proof_submission_rate_limit_web' => 5,
        'voucher_value_hearing_disability' => 500
      }
      Policy.where(key: defaults.keys).destroy_all
      get admin_policies_path
      assert_response :success
      assert_policy_editor('System Policies')
      bulk_form = css_select("form[action='#{bulk_update_admin_policies_path}']").sole
      assert_empty bulk_form.css('input[name="policy[key]"]')
      defaults.each do |key, default|
        creation = css_select("form[action='#{admin_policies_path}']").find do |form|
          form.at_css('input[name="policy[key]"]')&.[]('value') == key
        end
        assert creation, "missing independent creation form for #{key}"
        assert_equal '_top', creation['data-turbo-frame']
        assert_empty creation.ancestors('form')
        assert_equal default.to_s, creation.at_css('input[name="policy[value]"]')['value']
        assert_empty creation.css('input[name="policies[][id]"]')
      end
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

    private

    def assert_policy_editor(title)
      assert_select 'turbo-frame#policies', count: 1
      assert_select "form[action='#{bulk_update_admin_policies_path}'][data-turbo-frame='_top']", count: 1
      assert_select 'h1', text: title, count: 1
      assert_select 'h1', count: 1
      assert_select 'main main', count: 0
      assert_select "a[href='#{admin_dashboard_path}'][data-turbo-frame='_top']", text: 'Back to Dashboard'
      assert_select "a[href='#{admin_feature_flags_path}'][data-turbo-frame='_top']", text: 'Feature Flags'
      assert_select "a[href='#{admin_applications_path}']", text: 'Back to Applications', count: 0
      numbers = css_select('input[type="number"]')
      assert_not_empty numbers
      ids = numbers.pluck('id')
      assert ids.all?(&:present?), 'every numeric input needs a stable id'
      assert_equal ids.uniq, ids, 'numeric input ids must be unique'
      ids.each { |id| assert_select "label[for='#{id}']", count: 1 }
      assert_select 'input[name="policies[][id]"][id]', count: 0
      assert_select 'form form', count: 0
    end
  end
end
