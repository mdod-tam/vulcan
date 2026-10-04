# frozen_string_literal: true

require 'test_helper'

class AuthenticationVerificationTest < ActionDispatch::IntegrationTest
  setup do
    ENV['DEBUG_AUTH'] = 'true'

    @user = create(:constituent)
  end

  test 'sign_in_with_headers sets cookies and permits an applications request' do
    sign_in_with_headers(@user)

    Rails.logger.debug 'VERIFICATION: After sign_in'
    Rails.logger.debug { "VERIFICATION: Cookies: #{cookies.inspect}" }
    Rails.logger.debug { "VERIFICATION: Session token in cookies: #{cookies[:session_token]}" }
    Rails.logger.debug { "VERIFICATION: Signed session token: #{cookies.signed[:session_token]}" } if cookies.respond_to?(:signed)

    assert_not_nil cookies[:session_token], 'Session token cookie not set'
    assert_not_nil cookies.signed[:session_token], 'Signed session token cookie not set' if cookies.respond_to?(:signed)

    get constituent_portal_applications_path

    Rails.logger.debug 'VERIFICATION: After accessing protected page'
    Rails.logger.debug { "VERIFICATION: Response status: #{response.status}" }
    Rails.logger.debug { "VERIFICATION: Response location: #{response.location}" } if response.redirect?

    assert_response :success, "Expected to access protected page, but was redirected to #{response.location}"
  end

  test 'integration helper permits protected applications access' do
    sign_in_with_headers(@user)

    Rails.logger.debug 'VERIFICATION: After sign_in_with_headers'
    Rails.logger.debug { "VERIFICATION: Cookies: #{cookies.inspect}" }

    assert_not_nil cookies[:session_token], 'Session token cookie not set'
    assert_not_nil cookies.signed[:session_token], 'Signed session token cookie not set' if cookies.respond_to?(:signed)

    get constituent_portal_applications_path

    assert_response :success, "Expected to access protected page, but was redirected to #{response.location}"
  end

  test 'authentication persists across multiple requests' do
    sign_in_with_headers(@user)

    get constituent_portal_applications_path
    assert_response :success, 'First request failed'

    get new_constituent_portal_application_path
    assert_response :success, 'Second request failed'

    get root_path
    assert_redirected_to constituent_portal_dashboard_path
  end

  test 'signed-in draft submission casts the checkbox array to true' do
    sign_in_with_headers(@user)

    Rails.logger.debug 'VERIFICATION: After sign-in for checkbox-array submission'
    Rails.logger.debug { "VERIFICATION: Cookies: #{cookies.inspect}" }

    post constituent_portal_applications_path, params: {
      application: {
        maryland_resident: true,
        household_size: 3,
        annual_income: 50_000,
        self_certify_disability: %w[0 1],
        hearing_disability: true
      },
      medical_provider: {
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
    sign_in_with_headers(@user)

    get constituent_portal_applications_path

    controller = @controller

    assert_equal @user.id, controller.send(:current_user).id, 'current_user did not return the expected user'
  end

  test 'Authentication resolves the integration helper identity after a request' do
    sign_in_with_headers(@user)

    get constituent_portal_applications_path

    controller = @controller

    Rails.logger.debug { "VERIFICATION: Controller class: #{controller.class}" }
    Rails.logger.debug { "VERIFICATION: Controller includes Authentication: #{controller.class.included_modules.include?(Authentication)}" }

    assert_equal @user.id, controller.send(:current_user).id,
                 'Authentication module current_user did not return the expected user'
  end
end
