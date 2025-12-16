# frozen_string_literal: true

require 'test_helper'

module ConstituentPortal
  class ApplicationsControllerAutosaveTest < ActionDispatch::IntegrationTest
    include AuthenticationTestHelper

    setup do
      # Set up test data using factories
      @user = create(:constituent, :with_disabilities)
      @draft_application = create(:application, user: @user, status: :draft)

      # Sign in the user for all tests
      sign_in_for_integration_test(@user)

      # Set thread local context to skip proof validations in tests
      setup_paper_application_context
    end

    teardown do
      # Clean up thread local context after each test
      teardown_paper_application_context
    end

    #------------------------------------------
    # Tests for autosaving Application fields
    #------------------------------------------

    test 'should autosave Application field for existing draft' do
      # Test autosaving household_size for an existing application
      patch autosave_field_constituent_portal_application_path(@draft_application),
            params: { field_name: 'application[household_size]', field_value: '4' },
            as: :json

      # Verify the response
      assert_response :success
      assert_json_response(success: true)

      # Verify the application was updated
      @draft_application.reload
      assert_equal 4, @draft_application.household_size
    end

    test 'should autosave Application field for new draft' do
      # Delete the existing draft so a new one can be created
      @draft_application.destroy

      # Test autosaving for a new application (no ID provided)
      assert_difference('Application.count') do
        patch autosave_field_constituent_portal_applications_path,
              params: { field_name: 'application[household_size]', field_value: '3' },
              as: :json
      end

      # Verify the response
      assert_response :success
      response_data = response.parsed_body
      assert response_data['success']
      assert_not_nil response_data['applicationId']

      # Verify the application was created with correct values
      new_application = Application.find(response_data['applicationId'])
      assert_equal 3, new_application.household_size
      assert_equal 'draft', new_application.status
      assert_equal @user.id, new_application.user_id
    end

    test 'should not autosave invalid Application field' do
      # Test autosaving an invalid annual_income
      patch autosave_field_constituent_portal_application_path(@draft_application),
            params: { field_name: 'application[annual_income]', field_value: 'invalid' },
            as: :json

      # Verify the response indicates error
      assert_response :unprocessable_content
      response_data = response.parsed_body
      assert_not response_data['success']
      assert response_data['errors'].present?

      # Verify the application was not updated
      original_income = @draft_application.annual_income
      @draft_application.reload
      assert_equal original_income, @draft_application.annual_income
    end

    test 'should autosave boolean Application field' do
      # Test autosaving self_certify_disability
      patch autosave_field_constituent_portal_application_path(@draft_application),
            params: { field_name: 'application[self_certify_disability]', field_value: 'true' },
            as: :json

      # Verify the response
      assert_response :success
      assert_json_response(success: true)

      # Verify the boolean was correctly cast and saved
      @draft_application.reload
      assert_equal true, @draft_application.self_certify_disability
    end

    test 'should autosave medical provider fields' do
      # Test autosaving nested medical provider field
      patch autosave_field_constituent_portal_application_path(@draft_application),
            params: { field_name: 'application[medical_provider_attributes][name]', field_value: 'Dr. Jane Smith' },
            as: :json

      # Verify the response
      assert_response :success
      assert_json_response(success: true)

      # Verify the application was updated
      @draft_application.reload
      assert_equal 'Dr. Jane Smith', @draft_application.medical_provider_name
    end

    test 'should update last_visited_step when autosaving Application field' do
      field_name = 'application[household_size]'
      attribute_name = 'household_size' # The actual attribute name

      patch autosave_field_constituent_portal_application_path(@draft_application),
            params: { field_name: field_name, field_value: '5' },
            as: :json

      assert_response :success
      @draft_application.reload
      assert_equal attribute_name, @draft_application.last_visited_step
    end

    #------------------------------------------
    # Tests for autosaving User fields
    #------------------------------------------

    test 'should autosave User disability field' do
      # Test autosaving hearing_disability
      patch autosave_field_constituent_portal_application_path(@draft_application),
            params: { field_name: 'application[hearing_disability]', field_value: 'true' },
            as: :json

      # Verify the response
      assert_response :success
      assert_json_response(success: true)

      # Verify the user was updated
      @user.reload
      assert_equal true, @user.hearing_disability
    end

    test 'should autosave application as managing guardian' do
      # Create a dependent user first
      create(:constituent, :with_disabilities)

      # Test updating the application to be managed by current user
      patch autosave_field_constituent_portal_application_path(@draft_application),
            params: { field_name: 'application[managing_guardian_id]', field_value: @user.id.to_s },
            as: :json

      # Verify the response
      assert_response :success
      assert_json_response(success: true)

      # Verify the application was updated
      @draft_application.reload
      assert_equal @user.id, @draft_application.managing_guardian_id
    end

    test 'should create guardian relationship when setting up dependent application' do
      # This test simulates what would happen during full application creation
      # for a dependent rather than during autosave, since guardian relationships
      # are set up during the application creation process

      # Create a dependent user
      dependent = create(:constituent, :with_disabilities)

      # Ensure there's no existing relationship
      assert_equal 0, @user.guardian_relationships_as_guardian.count

      # Create an application for the dependent with @user as the managing guardian
      application = nil
      assert_difference('GuardianRelationship.count') do
        # Create relationship first (would normally happen during user setup)
        GuardianRelationship.create!(
          guardian_id: @user.id,
          dependent_id: dependent.id,
          relationship_type: 'Parent'
        )

        # Then create application with managing_guardian_id
        application = create(
          :application,
          user: dependent,
          managing_guardian: @user,
          status: :draft
        )
      end

      # Verify the relationships were created
      assert_equal 1, @user.guardian_relationships_as_guardian.count
      @user.reload
      assert @user.guardian?, 'User should be recognized as a guardian'
      assert_equal 'Parent', @user.relationship_types_for_dependent(dependent).first

      # Verify the application is set up
      assert application.for_dependent?, 'Application should be marked for a dependent'
      assert_equal @user.id, application.managing_guardian_id
    end

    test 'should update last_visited_step when autosaving User field' do
      field_name = 'application[hearing_disability]'
      attribute_name = 'hearing_disability' # The actual attribute name

      patch autosave_field_constituent_portal_application_path(@draft_application),
            params: { field_name: field_name, field_value: 'false' },
            as: :json

      assert_response :success
      @draft_application.reload
      assert_equal attribute_name, @draft_application.last_visited_step
    end

    #------------------------------------------
    # Tests for ignoring certain fields
    #------------------------------------------

    test 'should not autosave file upload fields' do
      # Test autosaving a file field
      patch autosave_field_constituent_portal_application_path(@draft_application),
            params: { field_name: 'application[income_proof]', field_value: 'some_file.pdf' },
            as: :json

      # Verify the response indicates error
      assert_response :unprocessable_content
      response_data = response.parsed_body
      assert_not response_data['success']
      assert response_data['errors'].present?
    end

    test 'should return error for non-autosavable address fields' do
      # Store original address value
      original_address = @user.physical_address_1

      # Test autosaving a physical address field
      patch autosave_field_constituent_portal_application_path(@draft_application),
            params: { field_name: 'application[physical_address_1]', field_value: '123 Main St Ignored' },
            as: :json

      # Verify the response indicates error
      assert_response :unprocessable_content
      response_data = response.parsed_body
      assert_not response_data['success']
      assert response_data['errors'].present?
      assert_includes response_data['errors']['application[physical_address_1]'].first, 'cannot be autosaved'

      # Verify the user's address was NOT updated
      @user.reload
      assert_equal original_address, @user.physical_address_1
    end

    #------------------------------------------
    # Helper methods
    #------------------------------------------

    def assert_json_response(expected)
      response_data = response.parsed_body
      expected.each do |key, value|
        assert_equal value, response_data[key.to_s], "Expected response to have #{key}=#{value}"
      end
    end
  end
end
