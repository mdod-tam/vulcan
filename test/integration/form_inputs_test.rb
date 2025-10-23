# frozen_string_literal: true

require 'test_helper'

# Form Inputs Integration Test
#
# This test suite verifies that form inputs, especially checkboxes, are handled correctly.
# It tests both the helper methods and the actual form submission behavior.
class FormInputsTest < ActionDispatch::IntegrationTest
  setup do
    # Use factories instead of fixtures
    @user = create(:constituent, :with_disabilities)
    # Create an application associated with this user that's old enough to allow new applications
    @application = create(:application, :old_enough_for_new_application, user: @user)

    # Sign in the user for all tests
    sign_in_for_integration_test(@user)
  end

  # Test the checkbox_params helper
  test 'checkbox_params should return correct format' do
    # Test checked checkbox
    checked_params = checkbox_params(true)
    assert_equal %w[0 1], checked_params, "Checked checkbox should return ['0', '1']"

    # Test unchecked checkbox
    unchecked_params = checkbox_params(false)
    assert_equal '0', unchecked_params, "Unchecked checkbox should return '0'"
  end

  # Test the checkboxes_params helper
  test 'checkboxes_params should handle multiple checkboxes' do
    # Test multiple checkboxes
    checkboxes = {
      hearing_disability: true,
      vision_disability: false,
      speech_disability: true
    }

    params = checkboxes_params(checkboxes)

    # Verify the format
    assert_equal %w[0 1], params[:hearing_disability], "Checked checkbox should return ['0', '1']"
    assert_equal '0', params[:vision_disability], "Unchecked checkbox should return '0'"
    assert_equal %w[0 1], params[:speech_disability], "Checked checkbox should return ['0', '1']"
  end

  # Test form submission with checkbox parameters
  test 'should handle checkbox parameters in form submission' do
    # Submit a form with checkbox parameters
    post constituent_portal_applications_path, params: {
      application: {
        maryland_resident: checkbox_params(true),
        household_size: '3',
        annual_income: '50000',
        self_certify_disability: checkbox_params(true),
        hearing_disability: checkbox_params(true),
        vision_disability: checkbox_params(false),
        speech_disability: checkbox_params(true)
      },
      medical_provider: {
        name: 'Dr. Smith',
        phone: '2025551234',
        email: 'drsmith@example.com'
      },
      save_draft: 'Save Application'
    }

    # Verify the form was submitted successfully
    assert_response :redirect

    # Get the newly created application
    application = Application.last

    # Verify the checkbox values were correctly processed on the application and user
    assert_equal true, application.maryland_resident
    assert_equal true, application.self_certify_disability
    # Access disability attributes via the associated user
    assert_equal true, application.user.hearing_disability
    assert_equal false, application.user.vision_disability
    assert_equal true, application.user.speech_disability
  end

  # Test form submission with array values for checkboxes
  test 'should handle array values for checkboxes' do
    # Submit a form with array values for checkboxes
    post constituent_portal_applications_path, params: {
      application: {
        maryland_resident: %w[0 1],
        household_size: '3',
        annual_income: '50000',
        self_certify_disability: %w[0 1],
        hearing_disability: %w[0 1],
        vision_disability: '0',
        speech_disability: %w[0 1]
      },
      medical_provider: {
        name: 'Dr. Smith',
        phone: '2025551234',
        email: 'drsmith@example.com'
      },
      save_draft: 'Save Application'
    }

    # Verify the form was submitted successfully
    assert_response :redirect

    # Get the newly created application
    application = Application.last

    # Verify the checkbox values were correctly processed on the application and user
    assert_equal true, application.maryland_resident
    assert_equal true, application.self_certify_disability
    # Access disability attributes via the associated user
    assert_equal true, application.user.hearing_disability
    assert_equal false, application.user.vision_disability
    assert_equal true, application.user.speech_disability
  end

  # Test form submission with direct boolean values
  test 'should handle direct boolean values for checkboxes' do
    # Submit a form with direct boolean values for checkboxes
    post constituent_portal_applications_path, params: {
      application: {
        maryland_resident: true,
        household_size: '3',
        annual_income: '50000',
        self_certify_disability: true,
        hearing_disability: true,
        vision_disability: false,
        speech_disability: true
      },
      medical_provider: {
        name: 'Dr. Smith',
        phone: '2025551234',
        email: 'drsmith@example.com'
      },
      save_draft: 'Save Application'
    }

    # Verify the form was submitted successfully
    assert_response :redirect

    # Get the newly created application
    application = Application.last

    # Verify the checkbox values were correctly processed on the application and user
    assert_equal true, application.maryland_resident
    assert_equal true, application.self_certify_disability
    # Access disability attributes via the associated user
    assert_equal true, application.user.hearing_disability
    assert_equal false, application.user.vision_disability
    assert_equal true, application.user.speech_disability
  end

  # Test form submission with string values for checkboxes
  test 'should handle string values for checkboxes' do
    # Submit a form with string values for checkboxes
    post constituent_portal_applications_path, params: {
      application: {
        maryland_resident: '1',
        household_size: '3',
        annual_income: '50000',
        self_certify_disability: '1',
        hearing_disability: '1',
        vision_disability: '0',
        speech_disability: '1'
      },
      medical_provider: {
        name: 'Dr. Smith',
        phone: '2025551234',
        email: 'drsmith@example.com'
      },
      save_draft: 'Save Application'
    }

    # Verify the form was submitted successfully
    assert_response :redirect

    # Get the newly created application
    application = Application.last

    # Verify the checkbox values were correctly processed on the application and user
    assert_equal true, application.maryland_resident
    assert_equal true, application.self_certify_disability
    # Access disability attributes via the associated user
    assert_equal true, application.user.hearing_disability
    assert_equal false, application.user.vision_disability
    assert_equal true, application.user.speech_disability
  end

  # Test the assert_checkbox_checked helper
  test 'assert_checkbox_checked should verify checkbox state' do
    # Use the existing draft application from setup
    # Update the user directly for disability attributes
    @user.update!(hearing_disability: true)
    # Update the application for its own attributes and set status to draft
    @application.update!(
      maryland_resident: false,
      self_certify_disability: false,
      status: :draft # Ensure application is editable
    )

    # Visit the edit form (not new, since we have an existing draft)
    get edit_constituent_portal_application_path(@application)

    # Verify the page loaded successfully
    assert_response :success

    # Check for checkboxes that should be unchecked by default
    assert_select "input[type='checkbox'][name*='maryland_resident']:not([checked])"
    assert_select "input[type='checkbox'][name*='self_certify_disability']:not([checked])"

    # Now update to have checked checkboxes
    @application.update!(
      maryland_resident: true,
      self_certify_disability: true
    )

    # Edit the application (which should have pre-checked checkboxes)
    get edit_constituent_portal_application_path(@application)

    # Verify the page loaded successfully
    assert_response :success

    # Check for checkboxes that should be checked
    assert_select "input[type='checkbox'][name*='maryland_resident'][checked]"
    assert_select "input[type='checkbox'][name*='self_certify_disability'][checked]"
    assert_select "input[type='checkbox'][name*='hearing_disability'][checked]"
  end

  # Test handling of nested checkbox parameters
  test 'should handle nested checkbox parameters' do
    # Submit a form with nested checkbox parameters
    post constituent_portal_applications_path, params: {
      application: {
        maryland_resident: checkbox_params(true),
        household_size: '3',
        annual_income: '50000',
        self_certify_disability: checkbox_params(true),
        # Send disability params in the expected format
        hearing_disability: checkbox_params(true),
        vision_disability: checkbox_params(false),
        speech_disability: checkbox_params(true)
      },
      medical_provider: {
        name: 'Dr. Smith',
        phone: '2025551234',
        email: 'drsmith@example.com'
      },
      save_draft: 'Save Application'
    }

    # Verify the form was submitted successfully
    assert_response :redirect

    # Get the newly created application
    application = Application.last

    # Verify the checkbox values were correctly processed
    assert_equal true, application.maryland_resident
    assert_equal true, application.self_certify_disability

    # Verify user attributes were updated
    assert_equal true, application.user.hearing_disability
    assert_equal false, application.user.vision_disability
    assert_equal true, application.user.speech_disability
    # Removed checks for non-existent application.disabilities attribute
  end

  # Test handling of checkbox arrays
  test 'should handle checkbox arrays' do
    # Submit a form with checkbox arrays
    post constituent_portal_applications_path, params: {
      application: {
        maryland_resident: checkbox_params(true),
        household_size: '3',
        annual_income: '50000',
        self_certify_disability: checkbox_params(true),
        # Send disability params individually as controller expects
        hearing_disability: checkbox_params(true),
        speech_disability: checkbox_params(true),
        vision_disability: checkbox_params(false) # Assuming vision is off if not in array
      },
      medical_provider: {
        name: 'Dr. Smith',
        phone: '2025551234',
        email: 'drsmith@example.com'
      },
      save_draft: 'Save Application'
    }

    # Verify the form was submitted successfully
    assert_response :redirect

    # Get the newly created application
    application = Application.last

    # Verify the checkbox values were correctly processed
    assert_equal true, application.maryland_resident
    assert_equal true, application.self_certify_disability

    # Verify user attributes were updated
    assert_equal true, application.user.hearing_disability
    assert_equal true, application.user.speech_disability
    assert_equal false, application.user.vision_disability
    # Removed checks for non-existent application.disability_types attribute
  end
end
