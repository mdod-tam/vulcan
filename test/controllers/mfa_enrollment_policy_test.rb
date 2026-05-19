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
