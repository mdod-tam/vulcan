# frozen_string_literal: true

# Shared support for AuthenticationTestHelper and SystemTestAuthentication.
module AuthenticationCore
  SESSION_COOKIE_NAME = 'session_token'
  def create_test_session(user)
    Session.create!(
      user: user,
      user_agent: 'Test Browser',
      ip_address: '127.0.0.1'
    )
  end

  def issue_test_session_cookie(user)
    @issued_test_session = create_test_session(user)
    ActionDispatch::TestRequest.create.cookie_jar.tap do |cookie_jar|
      cookie_jar.signed[SESSION_COOKIE_NAME] = @issued_test_session.session_token
      cookies[SESSION_COOKIE_NAME] = cookie_jar[SESSION_COOKIE_NAME]
    end
    @issued_test_session
  end

  def delete_session_cookie
    @issued_test_session&.destroy! if @issued_test_session&.persisted?
    @issued_test_session = nil
    cookies.delete(SESSION_COOKIE_NAME)
  end

  def clear_test_identity
    Current.reset
  end

  def verify_authentication_state(user)
    assert @controller, 'Make a request before checking its authentication'
    assert_equal user.id, @controller.send(:current_user)&.id, 'Request authenticated the wrong user'
    authenticated_session = @controller.send(:current_session)
    assert_predicate authenticated_session, :persisted?
    assert_equal user.id, authenticated_session.user_id
    assert_not_predicate authenticated_session, :expired?
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
end
