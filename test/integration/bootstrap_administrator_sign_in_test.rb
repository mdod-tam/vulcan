# frozen_string_literal: true

require 'test_helper'

# The bootstrap creates the administrator without a factor. Sign-in and MFA stay on their normal path.
class BootstrapAdministratorSignInTest < ActionDispatch::IntegrationTest
  PASSWORD = 'Correct-Horse-Battery-9!'
  EMAIL = 'ceremony.admin@example.test'

  test 'the bootstrapped administrator is held at MFA enrollment, then signs in with the enrolled factor' do
    Baseline::Bootstrap.run!(input: { email: EMAIL, first_name: 'Cere', last_name: 'Mony', password: PASSWORD }, out: StringIO.new)

    post sign_in_path, params: { email: EMAIL, password: PASSWORD }
    assert_redirected_to setup_two_factor_authentication_path
    get admin_dashboard_path
    assert_redirected_to setup_two_factor_authentication_path

    get new_credential_two_factor_authentication_path(type: 'totp')
    secret = css_select('input[name="secret"]').sole['value']
    post create_credential_two_factor_authentication_path(type: 'totp'),
         params: { code: ROTP::TOTP.new(secret).now, secret: secret, nickname: 'Bootstrap factor' }
    assert_redirected_to credential_success_two_factor_authentication_path(type: 'totp')

    delete sign_out_path
    post sign_in_path, params: { email: EMAIL, password: PASSWORD }
    assert_redirected_to verify_method_two_factor_authentication_path(type: 'totp')
    get admin_dashboard_path
    assert_redirected_to sign_in_path

    post process_verification_two_factor_authentication_path(type: 'totp'), params: { code: ROTP::TOTP.new(secret).at(Time.current + 30) }
    get admin_dashboard_path
    assert_response :success
  end
end
