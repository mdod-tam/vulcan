# frozen_string_literal: true

require 'test_helper'

module ConstituentPortal
  class ApplicationsControllerTest < ActionDispatch::IntegrationTest
    include ActionDispatch::TestProcess::FixtureFile
    include AuthenticationTestHelper

    setup do
      # Generate a unique email for each test to avoid uniqueness validation errors
      unique_email = "constituent_#{Time.now.to_i}_#{rand(1000)}@example.com"

      # Set up test data using factories with the unique email
      @user = create(:constituent, :with_disabilities, email: unique_email)
      @application = create(:application, user: @user)
      @valid_pdf = fixture_file_upload(Rails.root.join('test/fixtures/files/income_proof.pdf'), 'application/pdf')
      @valid_image = fixture_file_upload(Rails.root.join('test/fixtures/files/residency_proof.pdf'), 'application/pdf')

      # Sign in the user for all tests
      sign_in_for_integration_test(@user)

      # Enable debug logging for authentication issues
      ENV['DEBUG_AUTH'] = 'true'

      # Set thread local context to skip proof validations in tests
      setup_paper_application_context
    end

    teardown do
      # Clean up thread local context after each test
      teardown_paper_application_context
    end

    # Test that the checkbox handling works correctly
    test 'should handle array values for self_certify_disability' do
      # Create a unique user for this test to avoid 3-year validation
      unique_user = create(:constituent, :with_disabilities,
                           email: "checkbox_test_#{Time.now.to_i}_#{rand(1000)}@example.com")
      sign_in_for_integration_test(unique_user)

      # Simulate a form submission with an array value for self_certify_disability
      post constituent_portal_applications_path, params: {
        application: {
          maryland_resident: true,
          household_size: 3,
          annual_income: 50_000,
          self_certify_disability: checkbox_params(true), # Use our helper to simulate a checked checkbox
          hearing_disability: true
        },
        medical_provider: {
          name: 'Dr. Smith',
          phone: '2025551234',
          email: 'drsmith@example.com'
        },
        save_draft: 'Save Application'
      }

      # Check that the application was created
      assert_response :redirect

      # Get the newly created application
      application = Application.last

      # Verify that self_certify_disability was correctly cast to true
      assert_equal true, application.self_certify_disability
    end

    # Test that the new application page loads correctly
    test 'should get new' do
      # Access the new application page
      get new_constituent_portal_application_path

      # Verify the page loaded successfully
      assert_response :success
      assert_select 'h1', 'New Application'
    end

    # Test creating a draft application
    test 'should create application as draft' do
      # Create a unique user for this test to avoid 3-year validation
      unique_user = create(:constituent, :with_disabilities,
                           email: "draft_test_#{Time.now.to_i}_#{rand(1000)}@example.com")
      sign_in_for_integration_test(unique_user)

      # Submit a draft application
      assert_difference('Application.count') do
        post constituent_portal_applications_path, params: {
          application: {
            maryland_resident: true,
            household_size: 3,
            annual_income: 50_000,
            self_certify_disability: checkbox_params(true),
            hearing_disability: true
          },
          medical_provider: {
            name: 'Dr. Smith',
            phone: '2025551234',
            email: 'drsmith@example.com'
          },
          save_draft: 'Save Application'
        }
      end

      # Get the newly created application
      application = Application.last

      # Verify the application was created correctly
      assert_redirected_to constituent_portal_application_path(application)
      assert_equal 'draft', application.status
      assert_equal 'Dr. Smith', application.medical_provider_name
      assert_equal '2025551234', application.medical_provider_phone
      assert_equal 'drsmith@example.com', application.medical_provider_email
    end

    # Test creating an application as submitted with required proofs
    test 'should create application as submitted' do
      # Create a unique user for this test to avoid 3-year validation
      unique_user = create(:constituent, :with_disabilities,
                           email: "submitted_test_#{Time.now.to_i}_#{rand(1000)}@example.com")
      sign_in_for_integration_test(unique_user)

      # Submit an application with required proofs
      assert_difference('Application.count') do
        post constituent_portal_applications_path, params: {
          application: {
            maryland_resident: true,
            household_size: 3,
            annual_income: 50_000,
            self_certify_disability: checkbox_params(true),
            hearing_disability: checkbox_params(true), # Use proper checkbox format
            vision_disability: checkbox_params(false),
            speech_disability: checkbox_params(false),
            mobility_disability: checkbox_params(false),
            cognition_disability: checkbox_params(false),
            residency_proof: @valid_image,
            income_proof: @valid_pdf,
            medical_provider_attributes: {
              name: 'Dr. Smith',
              phone: '2025551234',
              email: 'drsmith@example.com'
            }
          },
          submit_application: 'Submit Application'
        }
      end

      # Get the newly created application
      application = Application.last

      # Verify the application was created correctly
      assert_redirected_to constituent_portal_application_path(application)
      assert_equal 'in_progress', application.status

      # Verify proofs were attached
      assert application.income_proof.attached?
      assert application.residency_proof.attached?
      assert_equal 'not_reviewed', application.income_proof_status
      assert_equal 'not_reviewed', application.residency_proof_status
    end

    test 'guardian should create application for a dependent' do
      # Setup: Create a guardian and a dependent user linked by GuardianRelationship
      guardian = create(:constituent, email: 'guardian.app.creator@example.com', phone: '5555550020')
      dependent = create(:constituent, email: 'dependent.app.subject@example.com', phone: '5555550021')
      GuardianRelationship.create!(guardian_id: guardian.id, dependent_id: dependent.id, relationship_type: 'parent')

      # Sign in as the guardian
      sign_in_for_integration_test guardian

      # Simulate submitting an application where the guardian selects the dependent
      # The controller logic will need to handle identifying the dependent based on params,
      # e.g., params[:application][:user_id] = dependent.id
      # The managing_guardian_id should be set to current_user.id (guardian.id)
      assert_difference('Application.count') do
        post constituent_portal_applications_path, params: {
          application: {
            user_id: dependent.id, # Explicitly setting the applicant user ID
            maryland_resident: true,
            household_size: 2,
            annual_income: 30_000,
            self_certify_disability: checkbox_params(true),
            hearing_disability: checkbox_params(true), # Use proper checkbox format and ensure at least one disability
            vision_disability: checkbox_params(false),
            speech_disability: checkbox_params(false),
            mobility_disability: checkbox_params(false),
            cognition_disability: checkbox_params(false),
            residency_proof: @valid_image, # Assuming proofs are needed for submission
            income_proof: @valid_pdf,
            medical_provider_attributes: {
              name: 'Dr. Child',
              phone: '2025551212',
              email: 'drchild@example.com'
            }
          },
          submit_application: 'Submit Application' # Trigger submission logic
        }
      end

      application = Application.last
      assert_redirected_to constituent_portal_application_path(application)

      # Verify the application is linked correctly
      assert_equal(dependent.id, application.user_id, 'Application user_id should be the dependent')
      assert_equal(guardian.id, application.managing_guardian_id, 'Application managing_guardian_id should be the guardian')
      assert_equal('in_progress', application.status) # Assuming submission leads to in_progress

      # Verify proofs were attached (if submitted)
      assert application.income_proof.attached?
      assert application.residency_proof.attached?
    end

    # Test that the application show page loads correctly
    test 'should show application' do
      # Access the application show page
      get constituent_portal_application_path(@application)

      # Verify the page loaded successfully
      assert_response :success
      assert_select 'h1', /Application ##{@application.id}/
    end

    # Test that the edit page loads correctly for draft applications
    test 'should get edit for draft application' do
      # Set the application to draft status
      @application.update!(status: :draft)

      # Access the edit page
      get edit_constituent_portal_application_path(@application)

      # Verify the page loaded successfully
      assert_response :success
    end

    # Test that users can't edit submitted applications
    test 'should not get edit for submitted application' do
      # First attach required proofs
      @application.income_proof.attach(@valid_pdf)
      @application.residency_proof.attach(@valid_image)

      # Then set the application to in_progress status (submitted)
      @application.update!(status: :in_progress)

      # Try to edit a submitted application
      get edit_constituent_portal_application_path(@application)

      # Should be redirected to application page with an alert
      assert_redirected_to constituent_portal_application_path(@application)
      assert_flash_message(:alert, 'This application has already been submitted and cannot be edited.')
    end

    # Test updating a draft application
    test 'should update draft application' do
      # Set the application to draft status
      @application.update!(status: :draft)

      # Update the application with at least one disability selected
      # The controller requires at least one disability to be selected
      patch constituent_portal_application_path(@application), params: {
        application: {
          household_size: 4,
          annual_income: 60_000,
          # Include disability information to pass validation
          hearing_disability: checkbox_params(true),
          vision_disability: checkbox_params(false),
          speech_disability: checkbox_params(false),
          mobility_disability: checkbox_params(false),
          cognition_disability: checkbox_params(false)
        }
      }

      # Verify the update was successful
      assert_redirected_to constituent_portal_application_path(@application)

      # Reload the application and verify changes
      @application.reload
      assert_equal 4, @application.household_size
      assert_equal 60_000, @application.annual_income

      # Verify user disability attributes were updated
      # These get applied to the user, not the application
      @user.reload
      assert_equal true, @user.hearing_disability
    end

    # Test submitting a draft application
    test 'should submit draft application' do
      # Use the existing application and set it to draft status instead of creating a new one
      @application.update!(
        status: :draft,
        household_size: 3,
        annual_income: 50_000,
        medical_provider_name: 'Dr. Smith',
        medical_provider_phone: '2025551234',
        medical_provider_email: 'drsmith@example.com'
      )

      # Submit the draft application
      patch constituent_portal_application_path(@application), params: {
        application: {
          household_size: 4,
          annual_income: 60_000,
          maryland_resident: true,
          self_certify_disability: true, # This is an application model field
          terms_accepted: true,
          information_verified: true,
          medical_release_authorized: true,
          hearing_disability: checkbox_params(true), # Must have at least one disability for submission
          vision_disability: checkbox_params(false),
          speech_disability: checkbox_params(false),
          mobility_disability: checkbox_params(false),
          cognition_disability: checkbox_params(false),
          residency_proof: @valid_image, # Added residency proof
          income_proof: @valid_pdf, # Added income proof
          medical_provider_attributes: {
            name: 'Dr. Smith',
            phone: '2025551234',
            email: 'drsmith@example.com'
          }
        },
        submit_application: 'Submit Application'
      }

      # Verify the submission was successful
      assert_redirected_to constituent_portal_application_path(@application)

      # Reload the application and verify status change
      @application.reload
      assert_equal 'in_progress', @application.status
    end

    # Test that submitted applications cannot be updated
    test 'should not update submitted application' do
      # First attach required proofs
      @application.income_proof.attach(@valid_pdf)
      @application.residency_proof.attach(@valid_image)

      # Set the application to in_progress status (submitted) and ensure starting values
      @application.update!(status: :in_progress, household_size: 3, annual_income: 50_000)

      # Attempt to update a submitted application
      patch constituent_portal_application_path(@application), params: {
        application: {
          household_size: 4,
          annual_income: 60_000
        }
      }

      # Verify the update was rejected by ensure_editable
      assert_redirected_to constituent_portal_application_path(@application)
      assert_flash_message(:alert, 'This application has already been submitted and cannot be edited.')

      # Reload the application and verify no changes were made
      @application.reload
      assert_equal 3, @application.household_size # Assuming original fixture value was 3
      assert_equal 50_000, @application.annual_income.to_i # Assuming original fixture value was 50000
    end

    # Test validation errors for invalid submission
    test 'should show validation errors for invalid submission' do
      # Submit an invalid application
      post constituent_portal_applications_path, params: {
        application: {
          maryland_resident: false,
          household_size: '',
          annual_income: ''
        },
        submit_application: 'Submit Application'
      }

      # Verify validation errors are shown
      assert_response :unprocessable_content

      # Check that errors are present in the response body - be flexible with specific wording
      assert_match(/maryland resident|residency/i, response.body)
      assert_match(/household size|size.*blank/i, response.body)
      assert_match(/annual income|income.*blank/i, response.body)
    end

    # Test showing uploaded document filenames
    test 'should show uploaded document filenames on show page' do
      # First attach files to the application
      @application.income_proof.attach(@valid_pdf)
      @application.residency_proof.attach(@valid_image)
      @application.save!

      # Access the application show page
      get constituent_portal_application_path(@application)

      # Verify the page shows the filenames
      assert_response :success
      assert_select 'p', /Filename:/
    end

    # Test FPL helper methods provide correct server-rendered data
    test 'helper methods should return correct FPL thresholds' do
      # Set up FPL policies with standard values for testing
      setup_fpl_policies

      # Access a page that uses the helpers to ensure they work in context
      get new_constituent_portal_application_path
      assert_response :success

      # Test the helper methods directly
      thresholds_json = @controller.fpl_thresholds_json
      modifier = @controller.fpl_modifier_value

      # Parse and verify the thresholds JSON
      thresholds = JSON.parse(thresholds_json)
      assert_equal 15_650, thresholds['1']
      assert_equal 21_150, thresholds['2']
      assert_equal 26_650, thresholds['3']
      assert_equal 32_150, thresholds['4']
      assert_equal 37_650, thresholds['5']
      assert_equal 43_150, thresholds['6']
      assert_equal 48_650, thresholds['7']
      assert_equal 54_150, thresholds['8']

      # Verify the modifier value
      assert_equal 400, modifier
    end

    # Test that user association is maintained during update
    test 'should maintain user association during update' do
      # Set up the application and make it a draft
      @application.update!(status: :draft,
                           household_size: 3,
                           annual_income: 50_000,
                           medical_provider_name: 'Good Health Clinic')

      # Update the application with new values and disability information (draft update - no submission)
      patch constituent_portal_application_path(@application), params: {
        application: {
          household_size: 5,
          annual_income: 75_000,
          # No more is_guardian field - instead managing_guardian would be set via managing_guardian_id
          hearing_disability: checkbox_params(true),
          vision_disability: checkbox_params(true),
          speech_disability: checkbox_params(false),
          mobility_disability: checkbox_params(false),
          cognition_disability: checkbox_params(false),
          medical_provider_attributes: {
            name: 'Dr. Jane Smith',
            phone: '2025559876',
            email: 'drjane@example.com'
          }
        }
        # NOTE: No submit_application param, so this is a draft update
      }

      # Verify the update was successful
      assert_redirected_to constituent_portal_application_path(@application)

      # Reload the application and verify changes
      @application.reload

      # Check application attributes were updated
      assert_equal 5, @application.household_size
      assert_equal 75_000, @application.annual_income

      # The medical provider name should be updated
      assert_equal 'Dr. Jane Smith', @application.medical_provider_name
      assert_equal '2025559876', @application.medical_provider_phone
      assert_equal 'drjane@example.com', @application.medical_provider_email

      # Most importantly, verify the user association was maintained
      assert_not_nil @application.user_id
      assert_equal @user.id, @application.user_id

      # Verify user disability attributes were updated
      @user.reload
      assert_equal true, @user.hearing_disability
      assert_equal true, @user.vision_disability
      assert_equal false, @user.speech_disability
      assert_equal false, @user.mobility_disability
      assert_equal false, @user.cognition_disability
    end

    # Test for updating an application to be managed by a guardian
    test 'should update application with managing guardian' do
      # Create a dependent user
      dependent = create(:constituent, :with_disabilities,
                         email: 'dependent_for_update_test@example.com')

      # Create an application for the dependent
      dependent_app = create(:application, user: dependent, status: :draft)

      # Set up guardian relationship between current user and dependent
      GuardianRelationship.create!(
        guardian_id: @user.id,
        dependent_id: dependent.id,
        relationship_type: 'parent'
      )

      # Update the dependent's application to have current user as managing_guardian (draft update)
      patch constituent_portal_application_path(dependent_app), params: {
        application: {
          managing_guardian_id: @user.id,
          household_size: 2,
          annual_income: 30_000,
          # Add disability information since this might be treated as a submission
          hearing_disability: checkbox_params(true),
          vision_disability: checkbox_params(false),
          speech_disability: checkbox_params(false),
          mobility_disability: checkbox_params(false),
          cognition_disability: checkbox_params(false)
        }
        # NOTE: No submit_application param - this is a draft update
      }

      # Verify the update was successful
      assert_redirected_to constituent_portal_application_path(dependent_app)

      # Reload the application and verify changes
      dependent_app.reload

      # Verify managing guardian was set correctly
      assert_equal @user.id, dependent_app.managing_guardian_id
      assert dependent_app.for_dependent?, 'Application should be marked as for a dependent'
      assert_equal 'parent', dependent_app.guardian_relationship_type
    end

    test 'should save address information to user during application creation' do
      # Create a unique user for this test to avoid 3-year validation
      unique_user = create(:constituent, :with_disabilities,
                           email: "address_creation_test_#{Time.now.to_i}_#{rand(1000)}@example.com")
      sign_in_for_integration_test(unique_user)

      # Ensure the user starts with no address information
      unique_user.update!(
        physical_address_1: nil,
        physical_address_2: nil,
        city: nil,
        state: nil,
        zip_code: nil
      )

      # Create an application with address information
      assert_difference('Application.count') do
        post constituent_portal_applications_path, params: {
          application: {
            maryland_resident: true,
            household_size: 3,
            annual_income: 50_000,
            self_certify_disability: checkbox_params(true),
            hearing_disability: checkbox_params(true),
            vision_disability: checkbox_params(false),
            speech_disability: checkbox_params(false),
            mobility_disability: checkbox_params(false),
            cognition_disability: checkbox_params(false),
            # Address fields that should be saved to the user model
            physical_address_1: '134 main st',
            physical_address_2: 'Apt 2B',
            city: 'baltimore',
            state: 'MD',
            zip_code: '21201'
          },
          medical_provider_attributes: {
            name: 'Dr. Smith',
            phone: '2025551234',
            email: 'drsmith@example.com'
          },
          save_draft: 'Save Application'
        }
      end

      # Verify the application was created
      application = Application.last
      assert_redirected_to constituent_portal_application_path(application)
      assert_equal 'draft', application.status

      # CRITICAL: Verify that the address information was saved to the user model
      unique_user.reload
      assert_equal '134 main st', unique_user.physical_address_1, 'Address line 1 should be saved to user'
      assert_equal 'Apt 2B', unique_user.physical_address_2, 'Address line 2 should be saved to user'
      assert_equal 'baltimore', unique_user.city, 'City should be saved to user'
      assert_equal 'MD', unique_user.state, 'State should be saved to user'
      assert_equal '21201', unique_user.zip_code, 'ZIP code should be saved to user'
    end

    test 'should save address information to user during application submission' do
      # Create a unique user for this test to avoid 3-year validation
      unique_user = create(:constituent, :with_disabilities,
                           email: "address_submission_test_#{Time.now.to_i}_#{rand(1000)}@example.com")
      sign_in_for_integration_test(unique_user)

      # Ensure the user starts with no address information
      unique_user.update!(
        physical_address_1: nil,
        physical_address_2: nil,
        city: nil,
        state: nil,
        zip_code: nil
      )

      # Submit an application with address information and required proofs
      assert_difference('Application.count') do
        post constituent_portal_applications_path, params: {
          application: {
            maryland_resident: true,
            household_size: 4,
            annual_income: 45_000,
            self_certify_disability: checkbox_params(true),
            hearing_disability: checkbox_params(true),
            vision_disability: checkbox_params(false),
            speech_disability: checkbox_params(false),
            mobility_disability: checkbox_params(false),
            cognition_disability: checkbox_params(false),
            # Address fields that should be saved to the user model
            physical_address_1: '456 Oak Street',
            physical_address_2: '',
            city: 'Silver Spring',
            state: 'MD',
            zip_code: '20901',
            residency_proof: @valid_image,
            income_proof: @valid_pdf,
            medical_provider_attributes: {
              name: 'Dr. Johnson',
              phone: '3015551234',
              email: 'drjohnson@example.com'
            }
          },
          submit_application: 'Submit Application'
        }
      end

      # Verify the application was submitted
      application = Application.last
      assert_redirected_to constituent_portal_application_path(application)
      assert_equal 'in_progress', application.status

      # CRITICAL: Verify that the address information was saved to the user model
      unique_user.reload
      assert_equal '456 Oak Street', unique_user.physical_address_1, 'Address line 1 should be saved to user'
      assert_equal '', unique_user.physical_address_2, 'Address line 2 should be saved to user (empty string)'
      assert_equal 'Silver Spring', unique_user.city, 'City should be saved to user'
      assert_equal 'MD', unique_user.state, 'State should be saved to user'
      assert_equal '20901', unique_user.zip_code, 'ZIP code should be saved to user'
    end

    test 'should save address information to dependent user when guardian creates application' do
      # Setup: Create a guardian and a dependent user linked by GuardianRelationship
      guardian = create(:constituent,
                        email: 'guardian.address.test@example.com',
                        phone: '5555550030',
                        # Guardian starts with existing address
                        physical_address_1: '999 Guardian Lane',
                        city: 'Bethesda',
                        state: 'MD',
                        zip_code: '20814')
      dependent = create(:constituent,
                         email: 'dependent.address.test@example.com',
                         phone: '5555550031',
                         # Start with no address information
                         physical_address_1: nil,
                         physical_address_2: nil,
                         city: nil,
                         state: nil,
                         zip_code: nil)
      GuardianRelationship.create!(guardian_id: guardian.id, dependent_id: dependent.id, relationship_type: 'parent')

      # Sign in as the guardian
      sign_in_for_integration_test guardian

      # Create application for dependent with address information
      assert_difference('Application.count') do
        post constituent_portal_applications_path, params: {
          application: {
            user_id: dependent.id, # Explicitly setting the applicant user ID
            maryland_resident: true,
            household_size: 2,
            annual_income: 30_000,
            self_certify_disability: checkbox_params(true),
            hearing_disability: checkbox_params(true),
            vision_disability: checkbox_params(false),
            speech_disability: checkbox_params(false),
            mobility_disability: checkbox_params(false),
            cognition_disability: checkbox_params(false),
            # Address fields that should be saved to the DEPENDENT user model
            physical_address_1: '789 Elm Avenue',
            physical_address_2: 'Unit 5',
            city: 'Rockville',
            state: 'MD',
            zip_code: '20850',
            residency_proof: @valid_image,
            income_proof: @valid_pdf,
            medical_provider_attributes: {
              name: 'Dr. Child',
              phone: '2025551212',
              email: 'drchild@example.com'
            }
          },
          submit_application: 'Submit Application'
        }
      end

      application = Application.last
      assert_redirected_to constituent_portal_application_path(application)

      # Verify the application is linked correctly
      assert_equal(dependent.id, application.user_id, 'Application user_id should be the dependent')
      assert_equal(guardian.id, application.managing_guardian_id, 'Application managing_guardian_id should be the guardian')

      # CRITICAL: Verify that the address information was saved to the DEPENDENT user model, not the guardian
      dependent.reload
      guardian.reload

      # Address should be saved to the dependent (the applicant)
      assert_equal '789 Elm Avenue', dependent.physical_address_1, 'Address line 1 should be saved to dependent user'
      assert_equal 'Unit 5', dependent.physical_address_2, 'Address line 2 should be saved to dependent user'
      assert_equal 'Rockville', dependent.city, 'City should be saved to dependent user'
      assert_equal 'MD', dependent.state, 'State should be saved to dependent user'
      assert_equal '20850', dependent.zip_code, 'ZIP code should be saved to dependent user'

      # Guardian's address should remain unchanged
      assert_equal '999 Guardian Lane', guardian.physical_address_1, 'Guardian address should not be affected'
      assert_equal 'Bethesda', guardian.city, 'Guardian city should not be affected'
    end
  end
end
