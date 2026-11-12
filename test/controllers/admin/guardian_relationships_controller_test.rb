# frozen_string_literal: true

require 'test_helper'

module Admin
  class GuardianRelationshipsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @admin = create(:admin)
      @guardian = create(:constituent)
      @dependent = create(:constituent)
      @relationship = create(:guardian_relationship, guardian_user: @guardian, dependent_user: @dependent)
      @other_relationship = create(:guardian_relationship, guardian_user: @guardian)
      @application = create(:application, user: @dependent, managing_guardian: @guardian)
      sign_in_for_integration_test(@admin, bypass_mfa_enrollment: true)
    end

    test 'removing the selected relationship preserves people applications and sibling relationships for either return destination' do
      assert_difference('GuardianRelationship.count', -1) do
        delete admin_guardian_relationship_path(@relationship)
      end
      assert_redirected_to admin_user_path(@guardian)
      assert_equal 'Guardian relationship removed successfully.', flash[:notice]
      assert_not GuardianRelationship.exists?(@relationship.id)
      assert GuardianRelationship.exists?(@other_relationship.id)
      @application.reload
      assert_equal [@dependent.id, @guardian.id], [@application.user_id, @application.managing_guardian_id]
      assert User.exists?(@guardian.id)
      assert User.exists?(@dependent.id)

      other_dependent = @other_relationship.dependent_user
      assert_difference('GuardianRelationship.count', -1) do
        delete admin_guardian_relationship_path(@other_relationship), params: { return_to: 'dependent' }
      end
      assert_redirected_to admin_user_path(other_dependent)
      assert User.exists?(other_dependent.id)
      assert Application.exists?(@application.id)
    end

    test 'an unknown relationship cannot remove an existing relationship' do
      missing_id = GuardianRelationship.maximum(:id) + 1
      assert_no_difference ['GuardianRelationship.count', 'User.count', 'Application.count'] do
        delete admin_guardian_relationship_path(missing_id)
      end
      assert_response :not_found
      assert GuardianRelationship.exists?(@relationship.id)
      assert GuardianRelationship.exists?(@other_relationship.id)
    end

    test 'a constituent cannot remove their guardian relationship through the admin endpoint' do
      sign_in_for_integration_test(@dependent)
      assert_no_difference ['GuardianRelationship.count', 'Event.count'] do
        delete admin_guardian_relationship_path(@relationship)
      end
      assert_redirected_to root_path
      assert GuardianRelationship.exists?(@relationship.id)
      assert_equal @guardian.id, @application.reload.managing_guardian_id
    end
  end
end
