# frozen_string_literal: true

require 'test_helper'

module Admin
  # The index, show and search views read guardian and capability data through the model's own associations.
  # These tests check what they render for mixed relationship shapes, and that the associations are loaded
  # ahead of the rows instead of per row.
  class UsersAssociationsTest < ActionDispatch::IntegrationTest
    include AuthenticationTestHelper

    setup do
      @admin = create(:admin)
      sign_in_for_integration_test(@admin)
      build_family
    end

    test 'the index shows each relationship shape, role badge and capability control' do
      get admin_users_path(q: 'Family')

      assert_response :success
      assert_select "tr:has(a[href='#{admin_user_path(@guardian)}'])" do
        assert_select 'svg[aria-label="Guardian Icon"]'
        assert_select 'span', text: '(2 dependents)'
        assert_select 'li', text: /Guardian of #{Regexp.escape(@child.full_name)}/
        assert_select 'li', text: /Guardian of #{Regexp.escape(@sibling.full_name)}/
      end
      assert_select "tr:has(a[href='#{admin_user_path(@child)}'])" do
        assert_select 'svg[aria-label="Dependent Icon"]'
        assert_select 'li', text: /Dependent of #{Regexp.escape(@guardian.full_name)}/
        assert_select 'li', text: /Dependent of #{Regexp.escape(@other_guardian.full_name)}/
        assert_select 'td', text: /\(Dependent\)/
      end
      assert_select "tr:has(a[href='#{admin_user_path(@evaluator)}'])" do
        assert_select 'span', text: 'Evaluator'
        assert_select 'input[data-capability=can_train]:not([disabled])'
        assert_select 'ul', 0
      end
      assert_select "tr:has(a[href='#{admin_user_path(@vendor)}']) span", text: 'Vendor'
    end

    test 'show lists the guardians and dependents from the loaded relationships' do
      get admin_user_path(@guardian)
      assert_select '#dependents_managed_list li', 2
      assert_select "#dependent_#{@child.id} a", text: @child.full_name

      get admin_user_path(@child)
      assert_select '#guardians_list li', 2
      assert_select "#guardian_#{@guardian.id}", 1
      assert_select "#guardian_#{@other_guardian.id}", 1

      get admin_user_path(@evaluator)
      assert_select 'p', text: /neither a guardian nor a dependent/
    end

    test 'search results carry the dependent count and guardian badges both search paths render' do
      get search_admin_users_path(q: 'Family', role: 'guardian')
      assert_select "li[data-user-id='#{@guardian.id}'][data-user-dependents-count='2']"
      assert_select "li[data-user-id='#{@guardian.id}'] span", text: '2 dependents'

      get admin_users_path(q: 'Family', role: 'dependent', turbo_frame_id: 'dependent_search_results')
      assert_select "li[data-user-id='#{@child.id}'][data-user-dependents-count='0'] span", text: 'Has guardian'
      assert_select "li[data-user-id='#{@guardian.id}'] span", text: 'Has guardian', count: 0
    end

    test 'the index and the search issue the same queries for one row as for a full page' do
      # One row that is both guardian and dependent runs every association query once, as a full page does.
      both = create(:constituent, first_name: 'Bea', last_name: 'Family')
      create(:guardian_relationship, guardian_user: both, dependent_user: create(:constituent, last_name: 'Family'))
      create(:guardian_relationship, guardian_user: create(:constituent, last_name: 'Family'), dependent_user: both)

      get admin_users_path # The first request of a session also loads its credentials.
      one_index = query_count { get admin_users_path(q: 'Bea') }
      assert_select 'tbody tr', 1
      one_search = query_count { get search_admin_users_path(q: 'Bea', role: 'guardian') }
      assert_select 'li[data-user-id]', 1

      create_list(:constituent, 10, :with_dependents, dependents_count: 2, last_name: 'Family')
      create_list(:constituent, 3, :with_guardian, last_name: 'Family')
      create_list(:evaluator, 4, last_name: 'Family')

      assert_equal(one_index, query_count { get admin_users_path(q: 'Family') })
      assert_select 'tbody tr', 20
      assert_equal(one_search, query_count { get search_admin_users_path(q: 'Family', role: 'guardian') })
      assert_select 'li[data-user-id]', 10
    end

    test 'constituent search preloads eligibility, products, contacts and grants at the selected limit' do
      first = build_search_applicant('BoundedSingle')
      get search_admin_users_path(q: first.first_name, role: 'constituent')
      one = query_count { get search_admin_users_path(q: first.first_name, role: 'constituent') }
      assert_select 'li[data-user-id]', 1
      9.times { |index| build_search_applicant("Bounded#{index}") }

      full = query_count { get search_admin_users_path(q: 'Bounded', role: 'constituent') }

      assert_select 'li[data-user-id]', 10
      assert_select 'li[data-user-products="Bounded Product"][data-user-eligible=true]', 10
      assert_equal one, full, 'query growth must stay bounded across selected applicants'
    end

    test 'multiple-guardian contact rendering agrees with the canonical unloaded user' do
      expected_email = User.find(@child.id).effective_email
      expected_phone = User.find(@child.id).effective_phone

      get search_admin_users_path(q: @child.first_name, role: 'constituent')

      assert_select "li[data-user-id='#{@child.id}'][data-user-email='#{expected_email}'][data-user-phone='#{expected_phone}']"
      get admin_users_path(q: @child.first_name)
      assert_select "a[href='mailto:#{expected_email}']", text: expected_email
    end

    test 'the search and show pages load the relationships ahead of the rows' do
      violations = strict_loading_violations do
        get search_admin_users_path(q: 'Family', role: 'guardian')
        get admin_users_path(q: 'Family', role: 'dependent', turbo_frame_id: 'dependent_search_results')
        get admin_user_path(@child)
        get admin_user_path(@guardian)
        get admin_users_path
      end

      assert_empty violations
    end

    private

    def build_family
      @guardian = create(:constituent, first_name: 'Gale', last_name: 'Family')
      @other_guardian = create(:constituent, first_name: 'Orrin', last_name: 'Family')
      @child = create(:constituent, first_name: 'Cody', last_name: 'Family', dependent_email: @other_guardian.email)
      @sibling = create(:constituent, first_name: 'Sam', last_name: 'Family')
      create(:guardian_relationship, guardian_user: @guardian, dependent_user: @child)
      create(:guardian_relationship, guardian_user: @other_guardian, dependent_user: @child)
      create(:guardian_relationship, guardian_user: @guardian, dependent_user: @sibling)
      @evaluator = create(:evaluator, last_name: 'Family')
      create(:role_capability, user: @evaluator, capability: 'can_train')
      @vendor = create(:vendor, last_name: 'Family')
    end

    def build_search_applicant(first_name)
      user = create(:constituent, first_name: first_name)
      create(:guardian_relationship, guardian_user: user, dependent_user: create(:constituent))
      create(:guardian_relationship, guardian_user: create(:constituent), dependent_user: user)
      application = create(:application, :rejected, user: user)
      application.products << create(:product, name: 'Bounded Product')
      user
    end

    def query_count(&)
      count = 0
      callback = lambda do |*, payload|
        count += 1 unless payload[:name].in?(%w[SCHEMA TRANSACTION]) # Cache hits count: they would still be per-row calls.
      end
      ActiveSupport::Notifications.subscribed(callback, 'sql.active_record', &)
      assert_response :success
      count
    end

    # A lazy association load on a User while strict loading is on, logged instead of raised.
    def strict_loading_violations
      violations = []
      subscriber = ActiveSupport::Notifications.subscribe('strict_loading_violation.active_record') do |*, payload|
        violations << "#{payload[:owner].name}##{payload[:reflection].name}"
      end
      previous_action = ActiveRecord.action_on_strict_loading_violation
      ActiveRecord.action_on_strict_loading_violation = :log
      User.strict_loading_by_default = true
      yield
      violations
    ensure
      User.strict_loading_by_default = false
      ActiveRecord.action_on_strict_loading_violation = previous_action
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end
  end
end
