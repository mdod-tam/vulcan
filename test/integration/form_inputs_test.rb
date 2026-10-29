# frozen_string_literal: true

require 'test_helper'

class FormInputsTest < ActionDispatch::IntegrationTest
  setup do
    @user = create(:constituent, :with_disabilities)
    @application = create(:application, :old_enough_for_new_application, user: @user)

    sign_in_for_integration_test(@user)
  end

  test 'checkbox_params should return correct format' do
    checked_params = checkbox_params(true)
    assert_equal '1', checked_params, "Checked checkbox should return '1'"

    unchecked_params = checkbox_params(false)
    assert_equal '0', unchecked_params, "Unchecked checkbox should return '0'"
  end

  test 'checkboxes_params should handle multiple checkboxes' do
    checkboxes = {
      hearing_disability: true,
      vision_disability: false,
      speech_disability: true
    }

    params = checkboxes_params(checkboxes)

    assert_equal '1', params[:hearing_disability], "Checked checkbox should return '1'"
    assert_equal '0', params[:vision_disability], "Unchecked checkbox should return '0'"
    assert_equal '1', params[:speech_disability], "Checked checkbox should return '1'"
  end

  test 'should handle checkbox parameters in form submission' do
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
      certifying_professional: {
        name: 'Dr. Smith',
        phone: '2025551234',
        email: 'drsmith@example.com'
      },
      save_draft: 'Save Application'
    }

    assert_response :redirect

    application = Application.last

    assert_equal true, application.maryland_resident
    assert_equal true, application.self_certify_disability
    assert_equal true, application.user.hearing_disability
    assert_equal false, application.user.vision_disability
    assert_equal true, application.user.speech_disability
  end

  # Browsers submit scalars. Strong parameters drop an array rather than letting it read as checked.
  test 'ignores array values for checkboxes instead of reading them as checked' do
    post constituent_portal_applications_path, params: {
      application: {
        maryland_resident: '1',
        household_size: '3',
        annual_income: '50000',
        self_certify_disability: '1',
        hearing_disability: '1',
        vision_disability: '0',
        speech_disability: %w[0 1]
      },
      certifying_professional: {
        name: 'Dr. Smith',
        phone: '2025551234',
        email: 'drsmith@example.com'
      },
      save_draft: 'Save Application'
    }

    assert_response :redirect

    application = Application.last

    assert_equal true, application.user.hearing_disability
    assert_equal false, application.user.vision_disability
    assert_equal false, application.user.speech_disability
  end

  test 'should handle direct boolean values for checkboxes' do
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
      certifying_professional: {
        name: 'Dr. Smith',
        phone: '2025551234',
        email: 'drsmith@example.com'
      },
      save_draft: 'Save Application'
    }

    assert_response :redirect

    application = Application.last

    assert_equal true, application.maryland_resident
    assert_equal true, application.self_certify_disability
    assert_equal true, application.user.hearing_disability
    assert_equal false, application.user.vision_disability
    assert_equal true, application.user.speech_disability
  end

  test 'should handle string values for checkboxes' do
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
      certifying_professional: {
        name: 'Dr. Smith',
        phone: '2025551234',
        email: 'drsmith@example.com'
      },
      save_draft: 'Save Application'
    }

    assert_response :redirect

    application = Application.last

    assert_equal true, application.maryland_resident
    assert_equal true, application.self_certify_disability
    assert_equal true, application.user.hearing_disability
    assert_equal false, application.user.vision_disability
    assert_equal true, application.user.speech_disability
  end

  test 'assert_checkbox_checked should verify checkbox state' do
    @user.update!(hearing_disability: true)
    # Draft status permits edits.
    @application.update!(
      maryland_resident: false,
      self_certify_disability: false,
      status: :draft
    )

    get edit_constituent_portal_application_path(@application)

    assert_response :success

    assert_select "input[type='checkbox'][name*='maryland_resident']:not([checked])"
    assert_select "input[type='checkbox'][name*='self_certify_disability']:not([checked])"

    @application.update!(
      maryland_resident: true,
      self_certify_disability: true
    )

    get edit_constituent_portal_application_path(@application)

    assert_response :success

    assert_select "input[type='checkbox'][name*='maryland_resident'][checked]"
    assert_select "input[type='checkbox'][name*='self_certify_disability'][checked]"
    assert_select "input[type='checkbox'][name*='hearing_disability'][checked]"
  end

  test 'should handle nested checkbox parameters' do
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
      certifying_professional: {
        name: 'Dr. Smith',
        phone: '2025551234',
        email: 'drsmith@example.com'
      },
      save_draft: 'Save Application'
    }

    assert_response :redirect

    application = Application.last

    assert_equal true, application.maryland_resident
    assert_equal true, application.self_certify_disability

    assert_equal true, application.user.hearing_disability
    assert_equal false, application.user.vision_disability
    assert_equal true, application.user.speech_disability
  end

  test 'should handle checkbox arrays' do
    post constituent_portal_applications_path, params: {
      application: {
        maryland_resident: checkbox_params(true),
        household_size: '3',
        annual_income: '50000',
        self_certify_disability: checkbox_params(true),
        hearing_disability: checkbox_params(true),
        speech_disability: checkbox_params(true),
        vision_disability: checkbox_params(false)
      },
      certifying_professional: {
        name: 'Dr. Smith',
        phone: '2025551234',
        email: 'drsmith@example.com'
      },
      save_draft: 'Save Application'
    }

    assert_response :redirect

    application = Application.last

    assert_equal true, application.maryland_resident
    assert_equal true, application.self_certify_disability

    assert_equal true, application.user.hearing_disability
    assert_equal true, application.user.speech_disability
    assert_equal false, application.user.vision_disability
  end
end
