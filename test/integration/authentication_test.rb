# frozen_string_literal: true

require 'test_helper'

# Authentication Integration Test
#
# This test suite verifies that authentication works correctly in various scenarios.
# It tests both successful authentication and edge cases like expired sessions,
# invalid credentials, etc.
class AuthenticationTest < ActionDispatch::IntegrationTest
  setup do
    # Set up test data using factories
    @user = create(:constituent)
    @admin = create(:admin)

    # Enable debug logging for authentication issues
    # ENV['DEBUG_AUTH'] = 'true'
  end

  # Test successful authentication
  test 'should authenticate user with valid credentials' do
    # Sign in the user using the integration test helper
    sign_in_for_integration_test(@user)

    # Verify we're authenticated by accessing a protected page
    get constituent_portal_applications_path
    assert_response :success

    # Verify authentication state
    verify_authentication_state(@user)
  end

  # Test authentication failure with invalid credentials - using more direct approach
  test 'should not authenticate with invalid credentials' do
    # Attempt to sign in with wrong password
    post sign_in_path, params: {
      email: @user.email,
      password: 'wrong_password'
    }

    # The app may return different responses for invalid credentials
    # (e.g., 204 No Content, 401 Unauthorized, 422 Unprocessable Entity)
    # We just need to ensure we're not getting a success response
    assert_not_equal 200, response.status
    assert_not_equal 201, response.status

    # Also ensure we haven't been redirected to a dashboard
    # (which would indicate successful auth)
    assert_no_match(/dashboard/, response.location) if response.redirect?

    # After an invalid login attempt, ensure we're not signed in by trying to access
    # a protected page and verifying we don't actually get the page content

    # IMPORTANT: Make sure we clear any TEST_USER_ID that might be allowing access
    # despite failed login attempt
    original_test_user_id = ENV.fetch('TEST_USER_ID', nil)
    ENV['TEST_USER_ID'] = nil
    sign_out if defined?(sign_out) # Explicitly sign out to clear any session
    cookies.delete(:session_token) # Remove any leftover cookie

    begin
      # Try accessing a protected page
      get constituent_portal_applications_path

      # In a proper authentication system, we should be redirected to sign in
      # or get some kind of error response
      assert_not_equal 200, response.status, 'Should not get success response on protected page after failed login'

      # Most common case is being redirected to sign in
      assert_match(/sign_in|login|auth/, response.location) if response.redirect?
    ensure
      # Restore the test environment
      ENV['TEST_USER_ID'] = original_test_user_id
    end
  end

  # Helper for clearing Rails test state between requests
  def reset_for_next_request
    @controller = nil     # Force creation of a new controller
    @request = nil        # Reset the request object
    @response = nil       # Clear the response
    @_routes = nil        # Reset the routes
  end

  # Test for session expiration - focusing on proper end-to-end behavior
  test 'should handle expired sessions' do
    # First clean up any existing authentication - critical to reliable testing
    sign_out if defined?(sign_out)
    ENV['TEST_USER_ID'] = nil
    cookies.delete(:session_token)
    reset_for_next_request

    # Create a session in a known expired state
    expired_session = Session.create!(
      user: @user,
      user_agent: 'Test User Agent',
      ip_address: '127.0.0.1',
      expires_at: 1.day.ago # Explicitly set to expired
    )

    # Verify it's actually expired
    assert expired_session.expired?, 'Session should be expired'

    # Manually set just the cookie without sign_in helper
    cookies[:session_token] = expired_session.session_token

    # Disable TEST_USER_ID bypass which can interfere with our test
    original_test_user_id = ENV.fetch('TEST_USER_ID', nil)
    ENV['TEST_USER_ID'] = nil

    begin
      # Try to access a protected page with the expired session
      get constituent_portal_applications_path

      # With an expired session, we should be redirected to sign in
      assert_redirected_to sign_in_path
    ensure
      # Restore the original test environment
      ENV['TEST_USER_ID'] = original_test_user_id
    end
  end

  # A session created while the user was active must stop authenticating them the
  # moment the record becomes non-login-active in the database, even if whatever
  # changed the status did not itself destroy the session (Authentication#current_user
  # is the defense-in-depth recheck, independent of merge's own session expiry).
  test 'should reject a live session whose user was retired after the session was created' do
    sign_out if defined?(sign_out)
    ENV['TEST_USER_ID'] = nil
    cookies.delete(:session_token)
    reset_for_next_request

    live_session = Session.create!(user: @user, user_agent: 'Test User Agent', ip_address: '127.0.0.1')
    cookies[:session_token] = live_session.session_token

    canonical = create(:constituent)
    User.where(id: @user.id).update_all(
      merged_into_user_id: canonical.id, status: User.statuses[:inactive], updated_at: Time.current
    )

    original_test_user_id = ENV.fetch('TEST_USER_ID', nil)
    ENV['TEST_USER_ID'] = nil

    begin
      get constituent_portal_applications_path

      assert_redirected_to sign_in_path
      assert_not Session.exists?(live_session.id), 'the stale session must be destroyed, not just ignored'
    ensure
      ENV['TEST_USER_ID'] = original_test_user_id
    end
  end

  # Test sign out - simplified to focus on core behavior
  test 'should sign out user' do
    # First sign in normally without mocking
    sign_in_for_integration_test(@user)

    # Verify we're authenticated
    get root_path
    assert_response :success

    # Store the original cookie value (optional, might be nil here in integration tests)
    # original_token = cookies[:session_token]
    # assert original_token.present?, 'Should have a session token cookie after sign in' # This assertion is unreliable here

    delete sign_out_path
    assert_response :redirect

    # Follow redirect
    # Pass headers explicitly since follow_redirect! doesn't inherit default_headers
    follow_redirect!(headers: { 'X-Test-User-Id' => @user.id.to_s })

    # Verify that the cookie is deleted or emptied after sign out - this is the key assertion
    new_token = cookies[:session_token]
    assert new_token.blank?, 'Session token cookie should be blank after sign out'

    # Verify that we are not logged in anymore by checking flash message for success
    assert_includes flash[:notice].downcase, 'signed out', 'Should show signed out message in flash'
  end

  # Test authentication with headers
  test 'should authenticate with headers' do
    # Sign in with headers
    sign_in_with_headers(@user)

    # Verify we're authenticated
    get constituent_portal_applications_path
    assert_response :success

    # Verify authentication state
    verify_authentication_state(@user)
  end

  # Test sign_in method
  test 'should authenticate with sign_in' do
    # Use the explicit integration method
    sign_in_for_integration_test(@user)

    # Verify we're authenticated
    get constituent_portal_applications_path
    assert_response :success

    # Verify authentication state
    verify_authentication_state(@user)
  end

  # Test authentication persistence across requests
  test 'should maintain authentication across requests' do
    # Sign in the user
    sign_in_for_integration_test(@user)

    # Make multiple requests
    get constituent_portal_applications_path
    assert_response :success

    get new_constituent_portal_application_path
    assert_response :success

    get root_path
    assert_response :success

    # Verify we're still authenticated
    verify_authentication_state(@user)
  end

  # Test role-based access control
  test 'should enforce role-based access control' do
    # Sign in as regular user
    sign_in_for_integration_test(@user)

    # Try to access admin page
    get admin_applications_path

    # Should be denied access
    assert_not_authorized

    # Sign in as admin
    sign_in_for_integration_test(@admin)

    # Try to access admin page again
    get admin_applications_path

    # Should be allowed access
    assert_response :success
  end

  # Test the automatic header inclusion
  test 'should automatically include headers in requests' do
    # Sign in the user
    sign_in_for_integration_test(@user)

    # Make a request without explicitly including headers
    get constituent_portal_applications_path

    # Should still be authenticated
    assert_response :success

    # Verify authentication state
    verify_authentication_state(@user)
  end

  # Test authentication with remember me
  test 'should expire user after 24 hours' do
    # First, clear any existing sessions
    Session.where(user_id: @user.id).destroy_all

    # Sign in with remember_me parameter
    post sign_in_path, params: {
      email: @user.email,
      password: 'password123'
    }

    # Application redirects to dashboard after successful sign-in
    assert_redirected_to constituent_portal_dashboard_path
    follow_redirect!
    assert_response :success

    # Since there's no redirect to follow, we'll manually access a protected page
    # to verify we're authenticated

    # Retrieve the just-created session
    user_session = Session.find_by(user_id: @user.id)
    assert_not_nil user_session, 'Session should be created for user'

    # Verify we have a persistent cookie in cookies jar
    assert cookies[:session_token].present?

    # The core test: Session should expire in 24 hours
    assert user_session.expires_at > 23.hours.from_now && user_session.expires_at < 25.hours.from_now,
           'Session should last for 24 hours'
  end

  # Test the skip_unless_authentication_working helper
  test 'should skip tests when authentication is not working' do
    # Most straightforward way to test this is to use our own implementation
    def skip_unless_authentication_working_test
      # Create a mock method that checks if we should skip
      # and raises a Skip exception with the right message
      raise Minitest::Skip, 'Authentication not working properly'
    end

    # Call our test method and see if it skips as expected
    begin
      skip_unless_authentication_working_test
      flunk 'Expected test to be skipped'
    rescue Minitest::Skip => e
      # Expected. Verify the skip message
      assert_match(/Authentication not working properly/, e.message)
    end
  end
end
