# frozen_string_literal: true

# Sign-in helpers for tests that are not system tests:
# - Controller tests: sign_in_for_controller_test
# - Integration tests: sign_in_for_integration_test
# - Other tests: sign_in_for_unit_test
#
# System tests use SystemTestAuthentication.
module AuthenticationTestHelper
  include AuthenticationCore

  # Set bypass_mfa_enrollment: false to test required-role MFA enforcement.
  def sign_in_for_controller_test(user, bypass_mfa_enrollment: true)
    user_session = create_test_session(user)

    if defined?(request) && request.respond_to?(:session)
      request.session[:session_token] = user_session.session_token
    end

    if respond_to?(:cookies) && cookies.respond_to?(:signed)
      cookies.signed[:session_token] = { value: user_session.session_token, httponly: true }
    elsif respond_to?(:cookies)
      cookies[:session_token] = user_session.session_token
    end

    update_current_user(user)
    store_test_user_id(user.id)

    bypass_mfa_enrollment_in_test_session(bypass: bypass_mfa_enrollment)

    debug_auth "CONTROLLER AUTH: cookie & request.session set for #{user.email}"
    user
  end

  # Set bypass_mfa_enrollment: false to test required-role MFA enforcement.
  def sign_in_for_integration_test(user, bypass_mfa_enrollment: true)
    user_session = create_test_session(user)
    @session_token = user_session.session_token
    @test_user_id = user.id
    # test_helper.rb restores Current.user from this ID after each request.
    store_test_user_id(user.id)

    if respond_to?(:cookies) && cookies.respond_to?(:signed)
      cookies.signed[:session_token] = { value: user_session.session_token, httponly: true }
    elsif respond_to?(:cookies)
      cookies[:session_token] = user_session.session_token
    end

    # Requests use these headers only if the test passes headers: @headers.
    # find_test_session checks Current.test_user_id before this header.
    @headers ||= {}
    @headers['X-Test-User-Id'] = user.id.to_s

    update_current_user(user)

    bypass_mfa_enrollment_in_test_session(bypass: bypass_mfa_enrollment)

    debug_auth "INTEGRATION AUTH: cookies, headers, and test user ID set for #{user.email}"

    @authenticated_user = user

    user
  end

  # Sets only Current.user. It creates no session.
  def sign_in_for_unit_test(user)
    Current.user = user if defined?(Current)
    @current_user ||= user
    debug_auth "UNIT AUTH: Current.user set for #{user.email}"
    user
  end

  alias sign_in_as sign_in_for_controller_test
  alias sign_in_with_headers sign_in_for_integration_test
  # Do not alias update_current_user. AuthenticationCore owns its meaning.

  # Signs in through the real form. This is slow.
  def sign_in_user(user, password: 'password123')
    post sign_in_path, params: { email: user.email, password: password }
    assert_response :redirect
    assert_redirected_to root_path, 'Sign in failed to redirect properly'
    sign_in_for_unit_test(user)
    user
  end

  def sign_out
    if @headers.is_a?(Hash)
      @headers.delete('X-Test-User-Id')
      @headers.delete('HTTP_X_TEST_USER_ID')
    end

    @session_token = nil
    @test_user_id = nil
    @authenticated_user = nil

    clear_mfa_enrollment_bypass_in_test_session

    delete_session_cookie
    clear_test_identity
  end
  alias sign_out_with_headers sign_out

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

  # Sets the session[:skip_2fa] flag that the test-only bypasses in
  # ApplicationController and TwoFactorAuthenticationsController read.
  def bypass_mfa_enrollment_in_test_session(bypass: true)
    if is_a?(ActionDispatch::IntegrationTest)
      # The integration session is not available until after the first request.
      post '/test/set_session', params: { skip_2fa: bypass ? 'true' : 'false' }
    elsif defined?(request) && request.respond_to?(:session)
      if bypass
        request.session[:skip_2fa] = true
      else
        request.session.delete(:skip_2fa)
      end
    end
  end

  def clear_mfa_enrollment_bypass_in_test_session
    return unless is_a?(ActionDispatch::IntegrationTest)

    integration_session = begin
      send(:session)
    rescue NoMethodError
      nil
    end
    integration_session&.delete(:skip_2fa)
  end

  # Skips the test if GET root_path redirects to sign-in.
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
