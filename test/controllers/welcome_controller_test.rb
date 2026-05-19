# frozen_string_literal: true

require 'test_helper'

class WelcomeControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = create(:constituent)
    sign_in_as(@user)
  end

  test 'should get index page' do
    get welcome_path
    assert_response :success
    assert_select 'h1', text: /Welcome to Maryland Accessible Telecommunications/
  end

  test 'should redirect to dashboard if user already has webauthn credentials' do
    # Create a webauthn credential for the user
    @user.webauthn_credentials.create!(
      external_id: SecureRandom.uuid,
      nickname: 'Test Key',
      public_key: 'test',
      sign_count: 0
    )

    get welcome_path
    assert_redirected_to constituent_portal_dashboard_path # Corrected path helper
  end

  test 'should allow viewing welcome page with force param even with credentials' do
    # Create a webauthn credential for the user
    @user.webauthn_credentials.create!(
      external_id: SecureRandom.uuid,
      nickname: 'Test Key',
      public_key: 'test',
      sign_count: 0
    )

    get welcome_path(force: 'true')
    assert_response :success
    assert_select 'h1', text: /Welcome to Maryland Accessible Telecommunications/
  end

  test 'should redirect to dashboard if user already has totp credentials' do
    @user.totp_credentials.create!(
      secret: ROTP::Base32.random_base32,
      nickname: 'Authenticator App',
      last_used_at: Time.current
    )

    get welcome_path

    assert_redirected_to constituent_portal_dashboard_path
  end

  test 'redirects to sign in when not authenticated' do
    sign_out
    get welcome_path
    assert_redirected_to sign_in_path
  end
end
