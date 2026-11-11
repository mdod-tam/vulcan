# frozen_string_literal: true

require 'test_helper'

class AuthenticationTest < ActionDispatch::IntegrationTest
  setup do
    @user = create(:constituent)
    @admin = create(:admin)
  end

  test 'valid credentials issue a session for protected requests' do
    post sign_in_path, params: { email: @user.email, password: 'password1234' }
    assert_redirected_to constituent_portal_dashboard_path
    assert cookies[:session_token].present?

    get constituent_portal_applications_path

    assert_response :success
    verify_authentication_state(@user)
  end

  test 'invalid credentials do not authenticate a protected request' do
    post sign_in_path, params: { email: @user.email, password: 'wrong_password' }
    assert_redirected_to sign_in_path
    assert_empty @user.sessions

    get constituent_portal_applications_path

    assert_redirected_to sign_in_path
  end

  %i[idle absolute].each do |deadline|
    test "the default helper cannot bypass #{deadline} session expiry" do
      sign_in_for_integration_test(@user)
      stored_session = @issued_test_session
      if deadline == :idle
        stored_session.update!(last_active_at: (Session::IDLE_TIMEOUT + 1.minute).ago)
      else
        stored_session.update!(expires_at: 1.minute.ago)
      end

      get constituent_portal_applications_path

      assert_redirected_to sign_in_path
      assert_not @controller.send(:current_user)
    end
  end

  test 'the default helper cannot bypass persisted session revocation' do
    sign_in_for_integration_test(@user)
    @issued_test_session.destroy!

    get constituent_portal_applications_path

    assert_redirected_to sign_in_path
    assert_empty @user.sessions.reload
  end

  %i[missing unsigned tampered].each do |cookie_state|
    test "the default helper cannot authenticate with a #{cookie_state} cookie" do
      sign_in_for_integration_test(@user)
      case cookie_state
      when :missing then cookies.delete('session_token')
      when :unsigned then cookies[:session_token] = @issued_test_session.session_token
      when :tampered then cookies[:session_token] = "#{cookies[:session_token]}tampered"
      end
      assert cookies[:session_token].blank? if cookie_state == :missing

      get constituent_portal_applications_path

      assert_redirected_to sign_in_path
    end
  end

  test 'test identity headers cannot authenticate without a signed cookie' do
    get constituent_portal_applications_path, headers: { 'X-Test-User-Id' => @user.id.to_s }, as: :json

    assert_response :unauthorized
    assert_equal 'authentication_required', response.parsed_body.fetch('error')
  end

  test 'an environment identity cannot authenticate without a signed cookie' do
    original = ENV.fetch('TEST_USER_ID', nil)
    ENV['TEST_USER_ID'] = @user.id.to_s

    get constituent_portal_applications_path, as: :json

    assert_response :unauthorized
    assert_equal 'authentication_required', response.parsed_body.fetch('error')
  ensure
    ENV['TEST_USER_ID'] = original
  end

  test 'an explicit unit actor does not authenticate an HTTP request' do
    sign_in_for_unit_test(@user)

    get constituent_portal_applications_path, as: :json

    assert_response :unauthorized
    assert_equal 'authentication_required', response.parsed_body.fetch('error')
    assert_empty @user.sessions
  end

  test 'the default helper tracks activity on its persisted session' do
    freeze_time do
      sign_in_for_integration_test(@user)
      stored_session = @issued_test_session
      absolute_expiry = stored_session.expires_at
      stored_session.update!(last_active_at: 2.minutes.ago)

      get constituent_portal_applications_path

      assert_response :success
      assert_equal Time.current, stored_session.reload.last_active_at
      assert_equal absolute_expiry, stored_session.expires_at
      verify_authentication_state(@user)
    end
  end

  test 'the default helper enforces required MFA enrollment' do
    sign_in_for_integration_test(@admin)

    get admin_applications_path

    assert_redirected_to setup_two_factor_authentication_path
  end

  test 'the explicit enrollment exception cannot enter verification without a pending challenge' do
    sign_in_for_integration_test(@admin, bypass_mfa_enrollment: true)
    get admin_applications_path
    assert_response :success

    get verify_two_factor_authentication_path

    assert_redirected_to sign_in_path
  end

  test 'the explicit enrollment exception still requires MFA after password sign in' do
    credential = @admin.totp_credentials.create!(
      secret: ROTP::Base32.random,
      nickname: 'Authenticator',
      last_used_at: 1.minute.ago
    )
    bypass_mfa_enrollment_in_test_session(bypass: true)

    assert_no_difference('Session.count') do
      post sign_in_path, params: { email: @admin.email, password: 'password1234' }
    end

    assert_redirected_to verify_method_two_factor_authentication_path(type: 'totp')
    assert_equal @admin.id, session[TwoFactorAuth::SESSION_KEYS[:temp_user_id]]
    assert cookies[:session_token].blank?
    assert_empty @admin.sessions.reload

    assert_difference('Session.count', 1) do
      post verify_method_two_factor_authentication_path(type: 'totp'),
           params: { code: ROTP::TOTP.new(credential.secret).now }
    end

    assert_redirected_to admin_dashboard_path
    assert cookies[:session_token].present?
    assert_nil session[TwoFactorAuth::SESSION_KEYS[:temp_user_id]]
    get admin_applications_path
    assert_response :success
    verify_authentication_state(@admin)
  end

  test 'sign out removes the bearer and leaves protected requests unauthenticated' do
    sign_in_for_integration_test(@user)
    get root_path
    assert_redirected_to constituent_portal_dashboard_path

    delete sign_out_path

    assert_redirected_to sign_in_path
    assert cookies[:session_token].blank?
    assert_empty @user.sessions.reload
    get constituent_portal_applications_path
    assert_redirected_to sign_in_path
  end

  test 'the helper cookie maintains authentication across requests' do
    sign_in_for_integration_test(@user)
    get constituent_portal_applications_path
    assert_response :success
    get new_constituent_portal_application_path
    assert_response :success
    get root_path
    assert_redirected_to constituent_portal_dashboard_path
    verify_authentication_state(@user)
  end

  test 'role access is independent of cookie authentication' do
    sign_in_for_integration_test(@user)
    get admin_applications_path
    assert_not_authorized

    sign_in_for_integration_test(@admin, bypass_mfa_enrollment: true)
    get admin_applications_path
    assert_response :success
  end
end
