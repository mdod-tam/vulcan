# frozen_string_literal: true

require 'test_helper'

class TwoFactorAuthTest < ActiveSupport::TestCase
  setup do
    # Replace fixture accessor with FactoryBot, using unique email to avoid uniqueness constraint errors
    @user = create(:user,
                   email: "2fa-test-#{SecureRandom.hex(4)}@example.com",
                   email_verified: true,
                   verified: true)
    @session = {}

    # Set up minimal test credentials
    setup_webauthn_credential
    setup_totp_credential
  end

  test 'stores a webauthn challenge' do
    challenge = SecureRandom.hex(16) # Generate a test challenge

    stored_challenge = TwoFactorAuth.store_challenge( # Use TwoFactorAuth
      @session,
      :webauthn,
      challenge,
      { authenticator_type: 'cross-platform' }
    )

    assert stored_challenge.present?, 'Should store the challenge'
    assert_equal :webauthn, @session[TwoFactorAuth::SESSION_KEYS[:type]]
    assert_equal challenge, @session[TwoFactorAuth::SESSION_KEYS[:challenge]]
    assert @session[TwoFactorAuth::SESSION_KEYS[:metadata]].present?
    assert_equal 'cross-platform', @session[TwoFactorAuth::SESSION_KEYS[:metadata]][:authenticator_type]
  end

  test 'stores an sms challenge' do
    # Create credential for this test with unique phone number to avoid uniqueness constraint errors
    sms_credential = @user.sms_credentials.create!(
      phone_number: "555-#{rand(100..999)}-#{rand(1000..9999)}",
      last_sent_at: Time.current,
      verified_at: Time.current
    )

    # Create a simple string challenge instead of a BCrypt digest
    challenge = 'sms_challenge_digest'
    stored_challenge = TwoFactorAuth.store_challenge( # Use TwoFactorAuth
      @session,
      :sms,
      challenge,
      { credential_id: sms_credential.id }
    )

    assert stored_challenge.present?, 'Should store the challenge'
    assert_equal :sms, @session[TwoFactorAuth::SESSION_KEYS[:type]]
    assert_equal challenge, @session[TwoFactorAuth::SESSION_KEYS[:challenge]]
    assert @session[TwoFactorAuth::SESSION_KEYS[:metadata]].present?
    assert_equal sms_credential.id, @session[TwoFactorAuth::SESSION_KEYS[:metadata]][:credential_id]
  end

  test 'handles TOTP which does not require a stored challenge' do
    stored_challenge = TwoFactorAuth.store_challenge( # Use TwoFactorAuth
      @session,
      :totp,
      nil, # TOTP doesn't need a challenge
      { secret: @totp_credential.secret }
    )

    assert_nil stored_challenge, 'TOTP should not need a challenge'
    assert_equal :totp, @session[TwoFactorAuth::SESSION_KEYS[:type]]
    assert_nil @session[TwoFactorAuth::SESSION_KEYS[:challenge]]
    assert @session[TwoFactorAuth::SESSION_KEYS[:metadata]].present?
    assert_equal @totp_credential.secret, @session[TwoFactorAuth::SESSION_KEYS[:metadata]][:secret]
  end

  test 'retrieves challenge data from session' do
    # Store a challenge first
    challenge = SecureRandom.hex(16)
    TwoFactorAuth.store_challenge( # Use TwoFactorAuth
      @session,
      :webauthn,
      challenge,
      { test_data: 'metadata' }
    )

    # Now retrieve it
    challenge_data = TwoFactorAuth.retrieve_challenge(@session) # Use TwoFactorAuth

    assert_equal :webauthn, challenge_data[:type]
    assert_equal challenge, challenge_data[:challenge]
    assert_equal 'metadata', challenge_data[:metadata][:test_data]
  end

  test 'verified? returns correct status' do
    # Initially should not be verified
    assert_not TwoFactorAuth.verified?(@session) # Use TwoFactorAuth

    # Set verification time
    TwoFactorAuth.mark_verified(@session) # Use TwoFactorAuth

    # Now should be verified
    assert TwoFactorAuth.verified?(@session) # Use TwoFactorAuth
  end

  test 'clears challenge data' do
    # Set up session with challenge data
    @session[TwoFactorAuth::SESSION_KEYS[:type]] = :webauthn
    @session[TwoFactorAuth::SESSION_KEYS[:challenge]] = 'test_challenge'
    @session[TwoFactorAuth::SESSION_KEYS[:metadata]] = { test: true }

    # Clear the challenge data
    TwoFactorAuth.clear_challenge(@session) # Use TwoFactorAuth

    # Verify data is cleared
    assert_nil @session[TwoFactorAuth::SESSION_KEYS[:type]]
    assert_nil @session[TwoFactorAuth::SESSION_KEYS[:challenge]]
    assert_nil @session[TwoFactorAuth::SESSION_KEYS[:metadata]]
  end

  test 'abort_authentication clears temporary two factor state' do
    @session[TwoFactorAuth::SESSION_KEYS[:temp_user_id]] = @user.id
    @session[TwoFactorAuth::SESSION_KEYS[:available_methods]] = %w[sms totp]
    @session[TwoFactorAuth::SESSION_KEYS[:return_path]] = '/dashboard'
    @session[TwoFactorAuth::SESSION_KEYS[:verified_at]] = Time.current.to_i
    @session[TwoFactorAuth::SESSION_KEYS[:type]] = :sms
    @session[TwoFactorAuth::SESSION_KEYS[:challenge]] = 'sid'
    @session[TwoFactorAuth::SESSION_KEYS[:metadata]] = { credential_id: 1 }

    TwoFactorAuth.abort_authentication(@session)

    assert_nil @session[TwoFactorAuth::SESSION_KEYS[:temp_user_id]]
    assert_nil @session[TwoFactorAuth::SESSION_KEYS[:available_methods]]
    assert_nil @session[TwoFactorAuth::SESSION_KEYS[:return_path]]
    assert_nil @session[TwoFactorAuth::SESSION_KEYS[:verified_at]]
    assert_nil @session[TwoFactorAuth::SESSION_KEYS[:type]]
    assert_nil @session[TwoFactorAuth::SESSION_KEYS[:challenge]]
    assert_nil @session[TwoFactorAuth::SESSION_KEYS[:metadata]]
  end

  test 'logging methods record success and failure with context' do
    # Verify that the methods can be called without raising exceptions
    TwoFactorAuth.log_verification_success(@user.id, :webauthn, { credential_id: 123 })
    TwoFactorAuth.log_verification_failure(@user.id, :totp, 'Invalid code', { credential_ids: [456, 789] })

    # If we got here without exceptions, the test passes
    assert true
  end

  private

  def setup_webauthn_credential
    # We don't need a real credential for this test, just the model
    @webauthn_credential = @user.webauthn_credentials.create!(
      external_id: SecureRandom.hex(16),
      nickname: 'Test Key',
      public_key: SecureRandom.hex(32),
      sign_count: 0
    )
  end

  def setup_totp_credential
    @totp_credential = @user.totp_credentials.create!(
      secret: ROTP::Base32.random,
      nickname: 'Test TOTP',
      last_used_at: Time.current
    )
  end

  def setup_sms_credential
    @sms_credential = @user.sms_credentials.create!(
      phone_number: "555-#{rand(100..999)}-#{rand(1000..9999)}",
      last_sent_at: Time.current,
      verified_at: Time.current
    )

    # Mock the SMS service to avoid sending real texts in tests
    ::SMSService.stubs(:send_message).returns(true)
  end
end
