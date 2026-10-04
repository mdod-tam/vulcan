# frozen_string_literal: true

require 'test_helper'

class AuthenticationTest < ActionDispatch::IntegrationTest
  setup do
    @user = create(:constituent)
    @admin = create(:admin)
  end

  test 'should authenticate user with valid credentials' do
    sign_in_for_integration_test(@user)

    get constituent_portal_applications_path
    assert_response :success

    verify_authentication_state(@user)
  end

  test 'should not authenticate with invalid credentials' do
    post sign_in_path, params: {
      email: @user.email,
      password: 'wrong_password'
    }

    assert_not_equal 200, response.status
    assert_not_equal 201, response.status

    assert_no_match(/dashboard/, response.location) if response.redirect?

    # Remove test identity so the protected request must use session authentication.
    original_test_user_id = ENV.fetch('TEST_USER_ID', nil)
    ENV['TEST_USER_ID'] = nil
    sign_out if defined?(sign_out)
    cookies.delete(:session_token)

    begin
      get constituent_portal_applications_path

      assert_not_equal 200, response.status, 'Should not get success response on protected page after failed login'

      assert_match(/sign_in|login|auth/, response.location) if response.redirect?
    ensure
      ENV['TEST_USER_ID'] = original_test_user_id
    end
  end

  def reset_for_next_request
    @controller = nil
    @request = nil
    @response = nil
    @_routes = nil
  end

  test 'should handle expired sessions' do
    sign_out if defined?(sign_out)
    ENV['TEST_USER_ID'] = nil
    cookies.delete(:session_token)
    reset_for_next_request

    expired_session = Session.create!(
      user: @user,
      user_agent: 'Test User Agent',
      ip_address: '127.0.0.1',
      expires_at: 1.day.ago
    )

    assert expired_session.expired?, 'Session should be expired'

    cookies[:session_token] = expired_session.session_token

    # The cookie selects the expired session without a test-identity bypass.
    original_test_user_id = ENV.fetch('TEST_USER_ID', nil)
    ENV['TEST_USER_ID'] = nil

    begin
      get constituent_portal_applications_path

      assert_redirected_to sign_in_path
    ensure
      ENV['TEST_USER_ID'] = original_test_user_id
    end
  end

  test 'should sign out user' do
    sign_in_for_integration_test(@user)

    get root_path
    assert_redirected_to constituent_portal_dashboard_path

    delete sign_out_path
    assert_response :redirect

    # follow_redirect! does not inherit the default headers.
    follow_redirect!(headers: { 'X-Test-User-Id' => @user.id.to_s })

    new_token = cookies[:session_token]
    assert new_token.blank?, 'Session token cookie should be blank after sign out'

    assert_includes flash[:notice].downcase, 'signed out', 'Should show signed out message in flash'
  end

  test 'should authenticate with headers' do
    sign_in_with_headers(@user)

    get constituent_portal_applications_path
    assert_response :success

    verify_authentication_state(@user)
  end

  test 'should authenticate with sign_in' do
    sign_in_for_integration_test(@user)

    get constituent_portal_applications_path
    assert_response :success

    verify_authentication_state(@user)
  end

  test 'should maintain authentication across requests' do
    sign_in_for_integration_test(@user)

    get constituent_portal_applications_path
    assert_response :success

    get new_constituent_portal_application_path
    assert_response :success

    get root_path
    assert_redirected_to constituent_portal_dashboard_path

    verify_authentication_state(@user)
  end

  test 'should enforce role-based access control' do
    sign_in_for_integration_test(@user)

    get admin_applications_path

    assert_not_authorized

    sign_in_for_integration_test(@admin)

    get admin_applications_path

    assert_response :success
  end

  test 'should automatically include headers in requests' do
    sign_in_for_integration_test(@user)

    get constituent_portal_applications_path

    assert_response :success

    verify_authentication_state(@user)
  end

  test 'should expire user after 24 hours' do
    Session.where(user_id: @user.id).destroy_all

    post sign_in_path, params: {
      email: @user.email,
      password: 'password123'
    }

    assert_redirected_to constituent_portal_dashboard_path
    follow_redirect!
    assert_response :success

    user_session = Session.find_by(user_id: @user.id)
    assert_not_nil user_session, 'Session should be created for user'

    assert cookies[:session_token].present?

    assert user_session.expires_at > 23.hours.from_now && user_session.expires_at < 25.hours.from_now,
           'Session should last for 24 hours'
  end
end
