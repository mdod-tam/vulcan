# frozen_string_literal: true

require 'test_helper'

module Admin
  class UsersControllerActiveAppTest < ActionDispatch::IntegrationTest
    setup do
      @admin = create(:admin)
      sign_in_for_integration_test @admin

      @guardian = create(:constituent)
      @dependent = create(:constituent)
      GuardianRelationship.create!(guardian_user: @guardian, dependent_user: @dependent, relationship_type: 'Parent')
    end

    test 'should correctly identify active app status for rejected application' do
      # The application is five years old, past the three-year waiting period. If has_active_app were
      # false, eligible_now would be true.
      create(:application, user: @dependent, status: :rejected, application_date: 5.years.ago)

      get dependents_admin_user_path(@guardian)
      assert_response :success

      assert_no_match 'Not eligible: active application exists', response.body
      assert_match 'Select', response.body
    end

    test 'show page allows starting paper application for dependent with rejected application' do
      create(:application, user: @dependent, status: :rejected, application_date: 5.years.ago)

      get admin_user_path(@guardian)
      assert_response :success

      assert_select "a[href='#{new_admin_paper_application_path(guardian_id: @guardian.id, dependent_id: @dependent.id)}']",
                    text: 'Start Paper Application'
    end

    test 'show page hides start paper application for dependent with blocking application' do
      create(:application, :in_progress, user: @dependent)

      get admin_user_path(@guardian)
      assert_response :success

      assert_select "a[href='#{new_admin_paper_application_path(guardian_id: @guardian.id, dependent_id: @dependent.id)}']",
                    false
    end
  end
end
