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
      # We set application_date to 5 years ago so that if has_active_app were false,
      # eligible_now would be true (assuming 3 year waiting period).
      create(:application, user: @dependent, status: :rejected, application_date: 5.years.ago)

      get dependents_admin_user_path(@guardian)
      assert_response :success

      # Since app date is 5 years ago, eligible_now should be true.
      # We should see the "Select" button, or at least NOT see "active application exists".

      assert_no_match 'Not eligible: active application exists', response.body
      # Assuming the view renders "Select" when eligible_now is true
      assert_match 'Select', response.body
    end
  end
end
