# frozen_string_literal: true

# Sign-in helpers for tests that are not system tests:
# - Controller tests: sign_in_for_controller_test
# - Integration tests: sign_in_for_integration_test
# - Other tests: sign_in_for_unit_test
#
# System tests use SystemTestAuthentication.
module AuthenticationTestHelper
  include AuthenticationCore

  # Business scenarios may explicitly skip enrollment; session authentication stays real.
  def sign_in_for_controller_test(user, bypass_mfa_enrollment: false)
    cookies.delete(SESSION_COOKIE_NAME)
    bypass_mfa_enrollment_in_test_session(bypass: bypass_mfa_enrollment)
    issue_test_session_cookie(user)
    debug_auth "REQUEST AUTH: signed session cookie set for #{user.email}"
    user
  end
  alias sign_in_for_integration_test sign_in_for_controller_test

  # Sets only Current.user. It creates no session.
  def sign_in_for_unit_test(user)
    Current.user = user if defined?(Current)
    @current_user ||= user
    debug_auth "UNIT AUTH: Current.user set for #{user.email}"
    user
  end

  alias sign_in_as sign_in_for_controller_test

  def sign_out
    delete_session_cookie
    bypass_mfa_enrollment_in_test_session(bypass: false)
    clear_test_identity
  end

  def assert_authentication_required
    assert_redirected_to sign_in_path
  end

  def assert_not_authorized
    assert_redirected_to root_path
    assert_match(/not authorized/i, flash[:alert])
  end

  # The flag affects enrollment and its landing page, not a pending MFA challenge.
  def bypass_mfa_enrollment_in_test_session(bypass: false)
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
end
