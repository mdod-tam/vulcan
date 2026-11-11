# frozen_string_literal: true

require 'test_helper'

class AuthenticationVerificationTest < ActionDispatch::IntegrationTest
  setup do
    @user = create(:constituent)
  end

  test 'the controller helper permits an applications request with a signed cookie' do
    sign_in_for_controller_test(@user)

    assert_not_nil cookies[:session_token], 'Session token cookie not set'
    assert_not_nil cookies.signed[:session_token], 'Signed session token cookie not set' if cookies.respond_to?(:signed)

    get constituent_portal_applications_path

    assert_response :success, "Expected to access protected page, but was redirected to #{response.location}"
  end

  test 'integration helper permits protected applications access' do
    sign_in_for_integration_test(@user)

    assert_not_nil cookies[:session_token], 'Session token cookie not set'
    assert_not_nil cookies.signed[:session_token], 'Signed session token cookie not set' if cookies.respond_to?(:signed)

    get constituent_portal_applications_path

    assert_response :success, "Expected to access protected page, but was redirected to #{response.location}"
  end

  test 'authentication persists across multiple requests' do
    sign_in_for_integration_test(@user)

    get constituent_portal_applications_path
    assert_response :success, 'First request failed'

    get new_constituent_portal_application_path
    assert_response :success, 'Second request failed'

    get root_path
    assert_redirected_to constituent_portal_dashboard_path
  end

  test 'signed-in draft submission casts the checkbox array to true' do
    sign_in_for_integration_test(@user)

    post constituent_portal_applications_path, params: {
      application: {
        maryland_resident: true,
        household_size: 3,
        annual_income: 50_000,
        self_certify_disability: %w[0 1],
        hearing_disability: true
      },
      certifying_professional: {
        name: 'Dr. Smith',
        phone: '2025551234',
        email: 'drsmith@example.com'
      },
      save_draft: 'Save Application'
    }

    assert_response :redirect, 'Expected redirect after form submission'

    application = Application.last

    assert_equal true, application.self_certify_disability, 'self_certify_disability was not cast to true'
  end

  test 'current_user returns the signed-in user after an applications request' do
    sign_in_for_integration_test(@user)

    get constituent_portal_applications_path

    controller = @controller

    assert_equal @user.id, controller.send(:current_user).id, 'current_user did not return the expected user'
  end

  test 'Authentication resolves the persisted helper session after a request' do
    sign_in_for_integration_test(@user)

    get constituent_portal_applications_path

    controller = @controller

    assert_equal @user.id, controller.send(:current_user).id,
                 'Authentication module current_user did not return the expected user'
  end
end
