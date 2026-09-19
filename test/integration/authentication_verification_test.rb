# frozen_string_literal: true

require 'test_helper'

# Authentication Verification Test
#
# This test suite is specifically designed to verify that our authentication
# helpers are working correctly in the test environment. It tests various
# authentication scenarios to ensure that cookies are being set correctly
# and that the current_user method is working as expected.
class AuthenticationVerificationTest < ActionDispatch::IntegrationTest
  setup do
    # Enable debug logging for authentication issues
    ENV['DEBUG_AUTH'] = 'true'

    # Set up test data using factories instead of fixtures
    @user = create(:constituent)
  end

  # Test the basic sign_in helper
  test 'sign_in_with_headers correctly authenticates user in integration tests' do
    # Sign in the user with headers - integration tests should use sign_in_with_headers
    sign_in_with_headers(@user)

    # Debug output
    Rails.logger.debug 'VERIFICATION: After sign_in'
    Rails.logger.debug { "VERIFICATION: Cookies: #{cookies.inspect}" }
    Rails.logger.debug { "VERIFICATION: Session token in cookies: #{cookies[:session_token]}" }
    Rails.logger.debug { "VERIFICATION: Signed session token: #{cookies.signed[:session_token]}" } if cookies.respond_to?(:signed)

    # Verify cookie is set
    assert_not_nil cookies[:session_token], 'Session token cookie not set'
    assert_not_nil cookies.signed[:session_token], 'Signed session token cookie not set' if cookies.respond_to?(:signed)

    # Verify we can access a protected page
    get constituent_portal_applications_path

    # Debug output
    Rails.logger.debug 'VERIFICATION: After accessing protected page'
    Rails.logger.debug { "VERIFICATION: Response status: #{response.status}" }
    Rails.logger.debug { "VERIFICATION: Response location: #{response.location}" } if response.redirect?

    # Verify we're not redirected to sign in
    assert_response :success, "Expected to access protected page, but was redirected to #{response.location}"
  end

  # Test the sign_in_with_headers helper
  test 'sign_in_with_headers correctly authenticates user' do
    # Sign in the user with headers
    sign_in_with_headers(@user)

    # Debug output
    Rails.logger.debug 'VERIFICATION: After sign_in_with_headers'
    Rails.logger.debug { "VERIFICATION: Cookies: #{cookies.inspect}" }

    # Verify cookie is set
    assert_not_nil cookies[:session_token], 'Session token cookie not set'
    assert_not_nil cookies.signed[:session_token], 'Signed session token cookie not set' if cookies.respond_to?(:signed)

    # Verify we can access a protected page
    get constituent_portal_applications_path

    # Verify we're not redirected to sign in
    assert_response :success, "Expected to access protected page, but was redirected to #{response.location}"
  end

  # Test authentication persistence across requests
  test 'authentication persists across multiple requests' do
    # Sign in the user
    sign_in_with_headers(@user)

    # Make multiple requests
    get constituent_portal_applications_path
    assert_response :success, 'First request failed'

    get new_constituent_portal_application_path
    assert_response :success, 'Second request failed'

    get root_path
    assert_redirected_to constituent_portal_dashboard_path
  end

  # Test the checkbox_test approach
  test 'checkbox_test approach works for authentication' do
    # Use the same approach as the checkbox test
    sign_in_with_headers(@user)

    # Debug output
    Rails.logger.debug 'VERIFICATION: After checkbox test approach'
    Rails.logger.debug { "VERIFICATION: Cookies: #{cookies.inspect}" }

    # Simulate a form submission like in the checkbox test
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

    # Check that the application was created
    assert_response :redirect, 'Expected redirect after form submission'

    # Get the newly created application
    application = Application.last

    # Verify that self_certify_disability was correctly cast to true
    assert_equal true, application.self_certify_disability, 'self_certify_disability was not cast to true'
  end

  # Test the controller's current_user method directly
  test 'controller current_user method works with our authentication' do
    # Sign in the user
    sign_in_with_headers(@user)

    # Access a page to get a controller instance
    get constituent_portal_applications_path

    # Get the controller instance
    controller = @controller

    # Verify current_user returns the correct user
    assert_equal @user.id, controller.send(:current_user).id, 'current_user did not return the expected user'
  end

  # Test the Authentication module's current_user method
  test 'Authentication module current_user method works with our cookies' do
    # Use sign_in_with_headers for reliable authentication in integration tests
    sign_in_with_headers(@user)

    # Access a page to get a controller instance
    get constituent_portal_applications_path

    # Get the controller instance
    controller = @controller

    # Debug output
    Rails.logger.debug { "VERIFICATION: Controller class: #{controller.class}" }
    Rails.logger.debug { "VERIFICATION: Controller includes Authentication: #{controller.class.included_modules.include?(Authentication)}" }

    # Verify current_user returns the correct user
    assert_equal @user.id, controller.send(:current_user).id,
                 'Authentication module current_user did not return the expected user'
  end
end
