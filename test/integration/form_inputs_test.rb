# frozen_string_literal: true

require 'test_helper'

class FormInputsTest < ActionDispatch::IntegrationTest
  setup do
    @user = create(:constituent, :with_disabilities)
    @application = create(:application, :old_enough_for_new_application, user: @user)

    sign_in_for_integration_test(@user)
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

  test 'scalar checkbox encodings persist the same checked and unchecked values' do
    [[true, false], %w[1 0]].each do |checked, unchecked|
      # Reset the opposite flags so the preceding payload cannot mask a dropped update.
      @user.update!(hearing_disability: false, vision_disability: true, speech_disability: false)
      @user.applications.draft.each { |draft| draft.update!(maryland_resident: false, self_certify_disability: false) }
      post constituent_portal_applications_path, params: {
        application: {
          maryland_resident: checked,
          household_size: '3',
          annual_income: '50000',
          self_certify_disability: checked,
          hearing_disability: checked,
          vision_disability: unchecked,
          speech_disability: checked
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
end
