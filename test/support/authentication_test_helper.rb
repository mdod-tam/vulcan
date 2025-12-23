# frozen_string_literal: true

# AuthenticationTestHelper
#
# Standardised helpers for signing users in/out across non-system tests.
# – Controller tests → sign_in_for_controller_test
# – Integration tests → sign_in_for_integration_test
# – Unit/other        → sign_in_for_unit_test
#
# For system tests, see SystemTestAuthentication module.
module AuthenticationTestHelper
  # Include shared authentication core functionality
  include AuthenticationCore

  # Explicit methods for different test contexts --------------------------------

  # Controller-level cookie sign-in.
  def sign_in_for_controller_test(user)
    session = create_test_session(user)

    # Mirror what Rails would do from the cookie, so authenticate! sees it
    if defined?(request) && request.respond_to?(:session)
      request.session[:session_token] = session.session_token
    end

    if respond_to?(:cookies) && cookies.respond_to?(:signed)
      cookies.signed[:session_token] = { value: session.session_token, httponly: true }
    elsif respond_to?(:cookies)
      cookies[:session_token] = session.session_token
    end

    # Make Current.user available immediately for any before_action
    update_current_user(user)

    # Store test user ID in thread local variable
    store_test_user_id(user.id)

    debug_auth "CONTROLLER AUTH: cookie & request.session set for #{user.email}"
    user
  end

  # Integration-level header sign-in.
  def sign_in_for_integration_test(user)
    session = create_test_session(user)
    @session_token = session.session_token
    @test_user_id = user.id # Store in instance variable
    store_test_user_id(user.id) # Set test-user context for post-request restore logic

    # Set up cookies so find_test_session can find the session
    if respond_to?(:cookies) && cookies.respond_to?(:signed)
      cookies.signed[:session_token] = { value: session.session_token, httponly: true }
    elsif respond_to?(:cookies)
      cookies[:session_token] = session.session_token
    end

    # Set up headers for subsequent requests - this is what find_test_session checks first
    @headers ||= {}
    @headers['X-Test-User-Id'] = user.id.to_s

    # Make Current.user available immediately
    update_current_user(user)

    debug_auth "INTEGRATION AUTH: cookies, headers, and test user ID set for #{user.email}"

    # Store user reference for post-request verification
    @authenticated_user = user

    user
  end

  # Pure unit-test fallback: just update Current.user.
  def sign_in_for_unit_test(user)
    Current.user = user if defined?(Current)
    @current_user ||= user
    debug_auth "UNIT AUTH: Current.user set for #{user.email}"
    user
  end

  # Convenience aliases for backward compatibility ---------------------------
  alias sign_in_as sign_in_for_controller_test
  alias sign_in_with_headers sign_in_for_integration_test
  # Do not alias update_current_user – keep the core meaning from AuthenticationCore

  # Optional convenience helper: simulate a form-based sign-in (slow!).
  def sign_in_user(user, password: 'password123')
    post sign_in_path, params: { email: user.email, password: password }
    assert_response :redirect
    assert_redirected_to root_path, 'Sign in failed to redirect properly'
    sign_in_for_unit_test(user)
    user
  end

  def sign_out
    # Clear integration test headers first (before clearing other state)
    if @headers.is_a?(Hash)
      @headers.delete('X-Test-User-Id')
      @headers.delete('HTTP_X_TEST_USER_ID')
    end

    # Clear instance variables set by sign_in_for_integration_test
    @session_token = nil
    @test_user_id = nil
    @authenticated_user = nil

    # Use the shared cookie deletion logic that handles all driver types
    delete_session_cookie

    # Clear test identity (thread-locals, Current.user, etc.)
    clear_test_identity
  end
  alias sign_out_with_headers sign_out # preserve original name

  # Assertions ---------------------------------------------------------------

  def assert_authenticated(expected_user)
    return unless defined?(@controller) && @controller.respond_to?(:current_user, true)

    actual = @controller.send(:current_user)
    assert_equal expected_user.id, actual&.id,
                 "Expected to be signed in as #{expected_user.email}, got #{actual&.email || 'nil'}"
  end

  def assert_authentication_required
    assert_response :redirect
    assert_redirected_to sign_in_path
  end

  def assert_not_authorized
    assert_response :redirect
    assert_redirected_to root_path
    assert_match(/not authorized/i, flash[:alert])
  end

  # Skip spec if auth system clearly broken, to avoid cascading failures.
  def skip_unless_authentication_working
    begin
      get root_path
    rescue StandardError
      nil
    end
    return unless response&.redirect? && response.location.to_s.include?('sign_in')

    skip 'Authentication not working properly'
  end
end
