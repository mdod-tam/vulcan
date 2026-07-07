# frozen_string_literal: true

require 'test_helper'

# A record can pass the password step and then be merged/deactivated before it completes
# 2FA. The session-cookie chokepoint must fail closed so a retired record never finishes
# authenticating even though its credentials still verify.
class MergedUserTwoFactorGateTest < ActionDispatch::IntegrationTest
  setup do
    @secret = ROTP::Base32.random_base32
    @user = create(:constituent, password: 'password123', password_confirmation: 'password123')
    @user.totp_credentials.create!(secret: @secret, nickname: 'Authenticator App', last_used_at: Time.current)
  end

  test 'user retired mid-flow cannot complete TOTP 2FA' do
    post sign_in_path, params: { email: @user.email, password: 'password123' }
    assert_equal @user.id, session[TwoFactorAuth::SESSION_KEYS[:temp_user_id]]

    canonical = create(:constituent)
    @user.update!(status: :active, merged_into_user: canonical, merged_at: Time.current)

    assert_no_difference '@user.sessions.count' do
      post process_verification_two_factor_authentication_path(type: 'totp'),
           params: { code: ROTP::TOTP.new(@secret).now }
    end

    assert_redirected_to sign_in_path
    follow_redirect!
    assert_no_match(/dashboard/i, request.path)
  end

  test 'active user completes TOTP 2FA and gets a session' do
    post sign_in_path, params: { email: @user.email, password: 'password123' }
    assert_equal @user.id, session[TwoFactorAuth::SESSION_KEYS[:temp_user_id]]

    assert_difference '@user.sessions.count', 1 do
      post process_verification_two_factor_authentication_path(type: 'totp'),
           params: { code: ROTP::TOTP.new(@secret).now }
    end

    assert_redirected_to constituent_portal_dashboard_path
  end
end
