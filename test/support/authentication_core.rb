# frozen_string_literal: true

# AuthenticationCore
#
# Core module providing shared authentication functionality for all test types.
# This module is intended to be used by both AuthenticationTestHelper and SystemTestAuthentication.
#
module AuthenticationCore
  # Session cookie name used across the application
  SESSION_COOKIE_NAME = :session_token
  # Creates a real Session row that all authentication methods can use
  def create_test_session(user)
    Session.create!(
      user: user,
      user_agent: 'Test Browser',
      ip_address: '127.0.0.1'
    )
  end

  # Deletes the session cookie from any type of driver (Capybara, Cuprite, Rack)
  # This centralizes cookie deletion logic that was duplicated across helper modules
  def delete_session_cookie
    # Rack mock session (integration tests)
    rack_mock_session.cookie_jar.delete(SESSION_COOKIE_NAME) if respond_to?(:rack_mock_session) && rack_mock_session.respond_to?(:cookie_jar)

    # Request session (controller tests)
    if defined?(request) && request.respond_to?(:session)
      request.session.delete(SESSION_COOKIE_NAME)
    end

    # Regular cookies for any test type
    cookies.delete(SESSION_COOKIE_NAME) if respond_to?(:cookies)

    # Browser-specific cookie deletion for system tests
    if defined?(page) && page.respond_to?(:driver)
      driver = page.driver

      # Cuprite driver
      if driver.is_a?(Capybara::Cuprite::Driver)
        begin
          if driver.respond_to?(:remove_cookie)
            driver.remove_cookie(SESSION_COOKIE_NAME.to_s)
          elsif driver.respond_to?(:clear_cookies)
            driver.clear_cookies
          end
        rescue StandardError => e
          debug_auth "Warning: Cuprite cookie deletion failed: #{e.message}"
        end
      end
    end

    # Capture the token before deleting the cookie
    token = nil
    token = cookies[SESSION_COOKIE_NAME] if defined?(Session) && respond_to?(:cookies) && cookies[SESSION_COOKIE_NAME].present?

    # Clean up sessions from the database to prevent growth if we captured a token
    return if token.blank?

    Session.where(session_token: token).delete_all
  end

  # Updates Current.user for the test environment
  def update_current_user(user)
    return unless defined?(Current)

    Current.user = user
  end

  # Clears Current.user and test identity
  def clear_test_identity
    # Clear specific Current attributes first
    if defined?(Current)
      Current.user = nil
      Current.test_user_id = nil
    end

    # Then reset the entire Current context
    Current.reset if defined?(Current) && Current.respond_to?(:reset)

    # Explicitly set test_user_id to nil again after reset
    Current.test_user_id = nil if defined?(Current) && Current.respond_to?(:test_user_id=)

    # For backward compatibility, also clear ENV variable
    ENV['TEST_USER_ID'] = nil if ENV['TEST_USER_ID'].present?
  end

  # Validate authentication state
  def verify_authentication_state(user)
    assert_equal user.id, Current.user&.id, 'Current.user wrong' if defined?(Current)

    assert_equal user.id, @controller.send(:current_user)&.id, 'controller current_user wrong' if defined?(@controller) && @controller.respond_to?(:current_user, true)

    session = Session.find_by(user_id: user.id)
    assert session.present?, 'No Session row'
    assert_not session.expired?, 'Session expired' if session.respond_to?(:expired?)
  end

  # Print debug information when DEBUG_AUTH env var is set to 'true'
  def debug_auth(msg)
    return unless ENV['DEBUG_AUTH'] == 'true' || ENV['VERBOSE_TESTS'] == 'true'

    if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
      Rails.logger.debug { "[AuthTest] #{msg}" }
    else
      puts "[AuthTest] #{msg}"
    end
  end

  # Stores the test user ID in a consistent way
  def store_test_user_id(user_id)
    Current.test_user_id = user_id
  end
end
