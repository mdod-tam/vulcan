# frozen_string_literal: true

require 'test_helper'

class TwoFactorAuthenticationSmsSelectionTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

  setup do
    @original_cache_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    @user = create(:constituent, email: 'sms-selection@example.com')
    @user.totp_credentials.create!(
      secret: ROTP::Base32.random_base32,
      nickname: 'Authenticator App',
      last_used_at: Time.current
    )
    @user.sms_credentials.create!(
      phone_number: '555-123-4567',
      last_sent_at: Time.current,
      verified_at: Time.current
    )
  end

  teardown do
    Rails.cache = @original_cache_store if @original_cache_store
  end

  test 'viewing authenticator app verification does not send SMS code' do
    TwilioVerifyService.expects(:send_verification).never

    start_password_step
    get verify_method_two_factor_authentication_path(type: 'totp')

    assert_response :success
    assert_select 'h1', text: 'Authenticator App Verification'
  end

  test 'viewing SMS verification page does not send SMS code' do
    TwilioVerifyService.expects(:send_verification).never

    start_password_step
    get verify_method_two_factor_authentication_path(type: 'sms')

    assert_response :success
    assert_select 'p', text: /Send a 6-digit code by text/
    assert_select 'a', text: 'Send verification code'
    assert_select 'a', text: "Didn't receive the code? Resend", count: 0
  end

  test 'choosing SMS verification sends one SMS code' do
    start_password_step

    TwilioVerifyService.expects(:send_verification).once.with('555-123-4567').returns(
      success: true,
      verification_sid: 'TEST_SMS_SELECTION',
      status: 'pending'
    )

    post select_sms_verification_two_factor_authentication_path

    assert_redirected_to verify_method_two_factor_authentication_path(type: 'sms')
    assert_response :see_other
    follow_redirect!
    assert_response :success
    assert_select 'p', text: /We've sent a 6-digit code by text/
  end

  test 'choosing SMS verification again reuses active challenge without sending another code' do
    start_password_step

    TwilioVerifyService.expects(:send_verification).once.with('555-123-4567').returns(
      success: true,
      verification_sid: 'TEST_SMS_SELECTION_IDEMPOTENT',
      status: 'pending'
    )

    post select_sms_verification_two_factor_authentication_path
    assert_redirected_to verify_method_two_factor_authentication_path(type: 'sms')

    post select_sms_verification_two_factor_authentication_path
    assert_redirected_to verify_method_two_factor_authentication_path(type: 'sms')
    assert_equal 'Enter the verification code we sent.', flash[:notice]
  end

  test 'SMS-only sign in sends one SMS code before showing verification page' do
    user = create(:constituent, email: 'sms-only-selection@example.com')
    user.sms_credentials.create!(
      phone_number: '555-987-6543',
      last_sent_at: Time.current,
      verified_at: Time.current
    )

    TwilioVerifyService.expects(:send_verification).once.with('555-987-6543').returns(
      success: true,
      verification_sid: 'TEST_SMS_ONLY_SELECTION',
      status: 'pending'
    )

    post sign_in_path, params: {
      email: user.email,
      password: 'password123'
    }

    assert_redirected_to verify_method_two_factor_authentication_path(type: 'sms')
    follow_redirect!
    assert_response :success
    assert_select 'p', text: /We've sent a 6-digit code by text/
  end

  private

  def start_password_step
    post sign_in_path, params: {
      email: @user.email,
      password: 'password123'
    }

    assert_redirected_to verify_two_factor_authentication_path
  end
end
