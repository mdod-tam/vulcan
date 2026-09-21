# frozen_string_literal: true

require 'test_helper'

class HomeControllerTest < ActionDispatch::IntegrationTest
  test 'visitors reach sign-in with registration and password recovery links' do
    get root_path

    assert_redirected_to sign_in_path
    assert_equal 'no-store', response.headers['Cache-Control']
    follow_redirect!
    assert_response :success
    assert_select 'h1', 'Sign In'
    assert_select 'a[href=?]', sign_up_path
    assert_select 'a[href=?]', new_password_path
    assert_select 'header a[aria-label=?][href=?]', 'Sign in to your account', sign_in_path
  end

  test 'visitors keep an allowed public locale' do
    get root_path(locale: 'es')

    assert_redirected_to sign_in_path(locale: 'es')
    follow_redirect!
    assert_select 'h1', 'Iniciar sesión'
    assert_select 'header a[aria-label=?][href=?]', 'Iniciar sesión en su cuenta', sign_in_path(locale: 'es')
    assert_select 'a[href=?]', sign_up_path(locale: 'es')
    assert_select 'a[href=?]', new_password_path(locale: 'es')
  end

  test 'unrecognized locales and supplied redirect destinations do not change the destination' do
    get root_path(locale: 'unknown', return_to: 'https://example.org')

    assert_redirected_to sign_in_path
  end

  {
    admin: :admin_dashboard_path,
    constituent: :constituent_portal_dashboard_path,
    vendor: :vendor_portal_dashboard_path,
    evaluator: :evaluators_dashboard_path,
    trainer: :trainers_dashboard_path,
    medical_provider: :edit_profile_path
  }.each do |role, destination|
    test "signed-in #{role} reaches the existing role destination" do
      user = role == :medical_provider ? create(:user, :medical_provider) : create(role)
      secret = ROTP::Base32.random_base32
      user.totp_credentials.create!(secret: secret, nickname: 'Authenticator')

      post sign_in_path, params: { email: user.email, password: 'password123' }
      assert_redirected_to verify_method_two_factor_authentication_path(type: 'totp')
      post process_verification_two_factor_authentication_path(type: 'totp'), params: { code: ROTP::TOTP.new(secret).now }
      assert_redirected_to public_send(destination)
      assert cookies[:session_token].present?

      get root_path

      assert_redirected_to public_send(destination)
      assert_equal 'no-store', response.headers['Cache-Control']
    end
  end

  test 'password-only constituents can reach their dashboard' do
    user = create(:constituent)
    post sign_in_path, params: { email: user.email, password: 'password123' }

    get root_path

    assert_redirected_to constituent_portal_dashboard_path
  end

  test 'expired sessions return to sign-in' do
    user = create(:constituent)
    post sign_in_path, params: { email: user.email, password: 'password123' }
    user.sessions.last.update!(expires_at: 1.minute.ago)

    get root_path

    assert_redirected_to sign_in_path
    assert cookies[:session_token].blank?
  end

  test 'pending MFA does not grant access to a dashboard' do
    user = create(:admin)
    user.totp_credentials.create!(secret: ROTP::Base32.random_base32, nickname: 'Authenticator')
    post sign_in_path, params: { email: user.email, password: 'password123' }
    assert_redirected_to verify_method_two_factor_authentication_path(type: 'totp')

    get root_path

    assert_redirected_to sign_in_path
    assert cookies[:session_token].blank?
  end

  test 'required MFA enrollment still precedes dashboard access' do
    user = create(:admin)
    post sign_in_path, params: { email: user.email, password: 'password123' }
    assert_redirected_to setup_two_factor_authentication_path

    get root_path

    assert_redirected_to setup_two_factor_authentication_path
  end

  test 'required password changes still precede MFA enrollment and dashboard access' do
    user = create(:admin, force_password_change: true)
    post sign_in_path, params: { email: user.email, password: 'password123' }

    get root_path

    assert_redirected_to edit_password_path
  end

  test 'access-denied notices survive the root redirect' do
    user = create(:constituent)
    post sign_in_path, params: { email: user.email, password: 'password123' }
    get admin_dashboard_path
    assert_redirected_to root_path
    notice = flash[:alert]
    assert notice.present?

    follow_redirect!
    assert_redirected_to constituent_portal_dashboard_path
    follow_redirect!

    assert_response :success
    assert_equal notice, flash[:alert]
    assert_select '[role="alert"]', text: /#{Regexp.escape(notice)}/
  end
end
