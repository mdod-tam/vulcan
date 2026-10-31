# frozen_string_literal: true

require 'test_helper'

class SessionCookieTest < ActionDispatch::IntegrationTest
  setup do
    Current.reset
  end

  test 'password sign-in sets a browser-session cookie with a 24-hour server deadline' do
    user = create(:constituent)

    freeze_time do
      assert_difference('Session.count') do
        post sign_in_path, params: { email: user.email, password: 'password1234' }
      end

      assert_redirected_to constituent_portal_dashboard_path
      assert_browser_session_cookie
      assert_equal 24.hours.from_now, user.sessions.last.expires_at
      session_record = user.sessions.last
      assert_nil session_record.session_token
      assert_match(/\A[0-9a-f]{64}\z/, session_record.session_token_digest)
      get edit_profile_path
      assert_response :success
      assert_difference -> { user.sessions.count }, -1 do
        delete sign_out_path
      end
      get edit_profile_path
      assert_redirected_to sign_in_path
    end
  end

  test 'registration sets the same browser-session cookie and 24-hour server deadline' do
    freeze_time do
      assert_difference(['User.count', 'Session.count']) do
        post sign_up_path, params: { user: {
          email: 'cookie-registration@example.com',
          password: 'password1234',
          password_confirmation: 'password1234',
          first_name: 'Cookie',
          last_name: 'Registration',
          date_of_birth: '1990-01-01',
          timezone: 'Eastern Time (US & Canada)',
          locale: 'en'
        } }
      end

      assert_redirected_to welcome_path
      assert_browser_session_cookie
      user = User.find_by_email('cookie-registration@example.com')
      assert_equal 24.hours.from_now, user.sessions.last.expires_at
      assert_nil user.sessions.last.session_token
      get edit_profile_path
      assert_response :success
    end
  end

  test 'a stored session digest cannot be replayed as the cookie token' do
    user = create(:constituent)
    post sign_in_path, params: { email: user.email, password: 'password1234' }
    cookies[:session_token] = user.sessions.last.session_token_digest

    get edit_profile_path

    assert_redirected_to sign_in_path
  end

  private

  def assert_browser_session_cookie
    cookie = Array(response.headers['Set-Cookie'])
             .flat_map { |header| header.split("\n") }
             .find { |header| header.start_with?('session_token=') }
    assert cookie, 'The live response must issue the session_token cookie'

    attributes = cookie.split(';').drop(1).map { |attribute| attribute.strip.downcase }
    assert_includes attributes, 'httponly'
    assert_includes attributes, 'samesite=lax'
    assert attributes.none? { |attribute| attribute.start_with?('expires=', 'max-age=') },
           'Browser-session cookies must not have a persistent expiry'
  end
end
