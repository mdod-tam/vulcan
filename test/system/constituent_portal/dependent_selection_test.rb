# frozen_string_literal: true

require 'application_system_test_case'

module ConstituentPortal
  class DependentSelectionTest < ApplicationSystemTestCase
    setup do
      # The timestamp keeps emails and 10-digit phone numbers unique.
      timestamp = Time.current.to_i

      @guardian = Users::Constituent.create!(
        email: "guardian.test.#{timestamp}@example.com",
        phone: "555123#{timestamp.to_s[-4..]}",
        first_name: 'Guardian',
        last_name: 'User',
        password: 'password123',
        password_confirmation: 'password123'
      )

      @dependent1 = Users::Constituent.create!(
        first_name: 'First',
        last_name: 'Dependent',
        email: "dep1.#{timestamp}@example.com",
        phone: "555234#{timestamp.to_s[-4..]}",
        password: 'password123',
        password_confirmation: 'password123'
      )

      @dependent2 = Users::Constituent.create!(
        first_name: 'Second',
        last_name: 'Dependent',
        email: "dep2.#{timestamp}@example.com",
        phone: "555345#{timestamp.to_s[-4..]}",
        password: 'password123',
        password_confirmation: 'password123'
      )

      GuardianRelationship.find_or_create_by!(
        guardian_id: @guardian.id,
        dependent_id: @dependent1.id
      ) do |relationship|
        relationship.relationship_type = 'Parent'
      end

      GuardianRelationship.find_or_create_by!(
        guardian_id: @guardian.id,
        dependent_id: @dependent2.id
      ) do |relationship|
        relationship.relationship_type = 'Legal Guardian'
      end

      system_test_sign_in(@guardian)

      visit constituent_portal_dashboard_path
      wait_for_turbo

      assert_text 'My Dashboard', wait: 10
    end

    test 'clicking Start Application from dashboard shows correct dependent name in title' do
      visit constituent_portal_dashboard_path
      wait_for_turbo

      assert_selector 'h4', text: 'My Dependents', wait: 5, visible: :all

      within('li', text: @dependent1.full_name, visible: :all) do
        click_on 'Start Application', visible: :all
      end

      wait_for_turbo

      assert_selector 'h1#form-title', text: "New Application for #{@dependent1.full_name}", wait: 5, visible: :all
    end

    test 'toggling between Myself and A dependent I manage radio buttons updates title correctly' do
      skip 'Applicant type is determined by URL params, not radio buttons'

      visit new_constituent_portal_application_path
      wait_for_turbo

      assert_checked_field 'Myself'
      assert_selector 'h1#form-title', text: 'New Application', wait: 5

      choose 'A dependent I manage'

      assert_selector '#dependent-selection-fields', visible: true, wait: 5

      select @dependent1.full_name, from: 'Select Dependent'

      assert_selector 'h1#form-title', text: "New Application for #{@dependent1.full_name}", wait: 5

      choose 'Myself'

      wait_for_turbo

      assert_selector 'h1#form-title', text: 'New Application', wait: 5

      element = find_by_id('dependent-selection-fields', visible: :all)
      assert element[:class].to_s.include?('hidden')
    end

    test 'selecting different dependents from dropdown updates title correctly' do
      skip 'Dependent selection is done via dashboard, not form dropdown'

      visit new_constituent_portal_application_path(user_id: @dependent1.id, for_self: false)
      wait_for_turbo

      assert_selector 'h1#form-title', text: "New Application for #{@dependent1.full_name}", wait: 5

      assert_checked_field 'A dependent I manage'

      assert_selector '#dependent_select_frame', visible: true

      select @dependent2.full_name, from: 'Select Dependent'

      assert_selector 'h1#form-title', text: "New Application for #{@dependent2.full_name}", wait: 5
    end

    test 'handles application form with url parameter for dependent' do
      visit new_constituent_portal_application_path(user_id: @dependent1.id, for_self: false)
      wait_for_turbo

      assert_selector 'h1#form-title', text: "New Application for #{@dependent1.full_name}", wait: 5
    end

    test 'handles application form with for_self=false parameter' do
      skip 'for_self=false requires user_id param to specify which dependent'

      visit new_constituent_portal_application_path(for_self: false)
      wait_for_turbo

      assert_checked_field 'A dependent I manage'

      assert_selector '#dependent_select_frame', visible: true, wait: 5

      within('#dependent_select_frame') do
        assert_selector 'select[data-dependent-selector-target="dependentSelect"]'
        assert_no_selector "option[selected][value='#{@dependent1.id}']"
        assert_no_selector "option[selected][value='#{@dependent2.id}']"
      end

      assert_selector 'h1#form-title', text: 'New Application', wait: 5

      select @dependent2.full_name, from: 'Select Dependent'

      assert_selector 'h1#form-title', text: "New Application for #{@dependent2.full_name}", wait: 5
    end
  end
end
