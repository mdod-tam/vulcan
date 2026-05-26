# frozen_string_literal: true

require 'test_helper'

class MfaEnrollmentPolicyTest < ActionDispatch::IntegrationTest
  test 'requires admins to enroll MFA before accessing application pages' do
    admin = create(:admin)
    sign_in_for_integration_test(admin, bypass_mfa_enrollment: false)

    get admin_dashboard_path

    assert_redirected_to setup_two_factor_authentication_path
  end

  test 'requires trainers to enroll MFA before accessing application pages' do
    trainer = create(:trainer)
    sign_in_for_integration_test(trainer, bypass_mfa_enrollment: false)

    get trainers_dashboard_path

    assert_redirected_to setup_two_factor_authentication_path
  end

  test 'requires evaluators to enroll MFA before accessing application pages' do
    evaluator = create(:evaluator)
    sign_in_for_integration_test(evaluator, bypass_mfa_enrollment: false)

    get evaluators_dashboard_path

    assert_redirected_to setup_two_factor_authentication_path
  end

  test 'requires vendors to enroll MFA before accessing application pages' do
    vendor = create(:vendor)
    sign_in_for_integration_test(vendor, bypass_mfa_enrollment: false)

    get vendor_portal_dashboard_path

    assert_redirected_to setup_two_factor_authentication_path
  end

  test 'allows required-role users without MFA to access MFA setup' do
    admin = create(:admin)
    sign_in_for_integration_test(admin, bypass_mfa_enrollment: false)

    get setup_two_factor_authentication_path

    assert_response :success
  end

  test 'forced password change notice uses global translation during MFA setup access' do
    admin = create(:admin, force_password_change: true)
    sign_in_for_integration_test(admin, bypass_mfa_enrollment: false)

    get setup_two_factor_authentication_path

    assert_redirected_to edit_password_path
    assert_equal I18n.t('controllers.application.check_password_change_required.password_security_change'),
                 flash[:notice]
    assert_no_match(/Translation missing/, flash[:notice])
  end

  test 'does not offer skip link to required-role users during MFA setup' do
    admin = create(:admin)
    sign_in_for_integration_test(admin, bypass_mfa_enrollment: false)

    get setup_two_factor_authentication_path

    assert_response :success
    assert_select 'a', text: /Skip for now/, count: 0
  end

  test 'does not offer skip link to required-role temp-session users during MFA setup' do
    admin = create(:admin)
    admin.totp_credentials.create!(
      secret: ROTP::Base32.random_base32,
      nickname: 'Authenticator App',
      last_used_at: Time.current
    )

    post sign_in_path, params: {
      email: admin.email,
      password: 'password123'
    }
    assert_redirected_to verify_method_two_factor_authentication_path(type: 'totp')

    get setup_two_factor_authentication_path(force: 'true')

    assert_response :success
    assert_select 'a', text: /Skip for now/, count: 0
  end

  test 'offers skip link to constituents during optional MFA setup' do
    constituent = create(:constituent)
    sign_in_for_integration_test(constituent, bypass_mfa_enrollment: false)

    get setup_two_factor_authentication_path

    assert_response :success
    assert_select 'a', text: /Skip for now/
  end

  test 'allows constituents without MFA to access their dashboard' do
    constituent = create(:constituent)
    sign_in_for_integration_test(constituent, bypass_mfa_enrollment: false)

    get constituent_portal_dashboard_path

    assert_response :success
  end

  test 'keeps required-role users with pending SMS setup out of application pages' do
    admin = create(:admin)
    sign_in_for_integration_test(admin, bypass_mfa_enrollment: false)

    assert_no_difference('SmsCredential.count') do
      post create_credential_two_factor_authentication_path(type: 'sms'), params: {
        phone_number: '555-123-4567'
      }
    end
    assert_redirected_to verify_pending_sms_credential_two_factor_authentication_path

    get admin_dashboard_path

    assert_redirected_to setup_two_factor_authentication_path
  end

  test 'keeps required-role users with legacy unverified SMS rows out of application pages' do
    admin = create(:admin)
    admin.sms_credentials.create!(
      phone_number: '555-123-4567',
      last_sent_at: Time.current
    )
    sign_in_for_integration_test(admin, bypass_mfa_enrollment: false)

    get admin_dashboard_path

    assert_redirected_to setup_two_factor_authentication_path
  end
end
