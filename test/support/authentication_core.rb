# frozen_string_literal: true

# Shared support for AuthenticationTestHelper and SystemTestAuthentication.
module AuthenticationCore
  SESSION_COOKIE_NAME = :session_token
  def create_test_session(user)
    Session.create!(
      user: user,
      user_agent: 'Test Browser',
      ip_address: '127.0.0.1'
    )
  end

  # Clear the cookie sources exposed by the current test driver.
  def delete_session_cookie
    # Rack mock session (integration tests)
    rack_mock_session.cookie_jar.delete(SESSION_COOKIE_NAME) if respond_to?(:rack_mock_session) && rack_mock_session.respond_to?(:cookie_jar)

    # Request session (controller tests)
    if defined?(request) && request.respond_to?(:session)
      request.session.delete(SESSION_COOKIE_NAME)
    end

    cookies.delete(SESSION_COOKIE_NAME) if respond_to?(:cookies)

    if defined?(page) && page.respond_to?(:driver)
      driver = page.driver

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

    # This lookup runs after cookie deletion and can return no token.
    token = nil
    token = cookies[SESSION_COOKIE_NAME] if defined?(Session) && respond_to?(:cookies) && cookies[SESSION_COOKIE_NAME].present?

    # Remove a Session row only if the cookie API still supplies its token.
    return if token.blank?

    Session.where(session_token: token).delete_all
  end

  def update_current_user(user)
    return unless defined?(Current)

    Current.user = user
  end

  def clear_test_identity
    if defined?(Current)
      Current.user = nil
      Current.test_user_id = nil
    end

    Current.reset if defined?(Current) && Current.respond_to?(:reset)

    Current.test_user_id = nil if defined?(Current) && Current.respond_to?(:test_user_id=)

    # Authentication also accepts TEST_USER_ID as a test identity source.
    ENV['TEST_USER_ID'] = nil if ENV['TEST_USER_ID'].present?
  end

  def verify_authentication_state(user)
    assert_equal user.id, Current.user&.id, 'Current.user wrong' if defined?(Current)

    assert_equal user.id, @controller.send(:current_user)&.id, 'controller current_user wrong' if defined?(@controller) && @controller.respond_to?(:current_user, true)

    session = Session.find_by(user_id: user.id)
    assert session.present?, 'No Session row'
    assert_not session.expired?, 'Session expired' if session.respond_to?(:expired?)
  end

  # DEBUG_AUTH or VERBOSE_TESTS enables these messages.
  def debug_auth(msg)
    return unless ENV['DEBUG_AUTH'] == 'true' || ENV['VERBOSE_TESTS'] == 'true'

    if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
      Rails.logger.debug { "[AuthTest] #{msg}" }
    else
      puts "[AuthTest] #{msg}"
    end
  end

  def store_test_user_id(user_id)
    Current.test_user_id = user_id
  end
end
