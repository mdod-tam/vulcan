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
        password: 'password1234',
        password_confirmation: 'password1234'
      )

      @dependent1 = Users::Constituent.create!(
        first_name: 'First',
        last_name: 'Dependent',
        email: "dep1.#{timestamp}@example.com",
        phone: "555234#{timestamp.to_s[-4..]}",
        password: 'password1234',
        password_confirmation: 'password1234'
      )

      @dependent2 = Users::Constituent.create!(
        first_name: 'Second',
        last_name: 'Dependent',
        email: "dep2.#{timestamp}@example.com",
        phone: "555345#{timestamp.to_s[-4..]}",
        password: 'password1234',
        password_confirmation: 'password1234'
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

    test 'handles application form with url parameter for dependent' do
      visit new_constituent_portal_application_path(user_id: @dependent1.id, for_self: false)
      wait_for_turbo

      assert_selector 'h1#form-title', text: "New Application for #{@dependent1.full_name}", wait: 5
    end
  end
end
