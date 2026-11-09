# frozen_string_literal: true

require 'test_helper'

class TwoFactorChallengeHydrationTest < ActiveSupport::TestCase
  PHONE = '555-111-2222'

  setup do
    @user = create(:constituent)
    @credential = @user.sms_credentials.create!(phone_number: PHONE, verified_at: Time.current)
  end

  test 'login proof is owned by one password flow and cannot hydrate another browser' do
    first_session = login_session
    second_session = login_session
    calls = []
    send_code = lambda do |_phone, **options|
      calls << options
      calls.size == 1 ? successful_send : { success: false }
    end

    TwilioVerifyService.stub(:send_verification, send_code) do
      first = TwoFactor::SmsLoginChallenge.new(session: first_session, credential: @credential)
      second = TwoFactor::SmsLoginChallenge.new(session: second_session, credential: @credential)
      assert_equal :sent, first.ensure_for!(@user)
      assert_equal :active, first.ensure_for!(@user)
      assert_equal false, second.ensure_for!(@user)
      assert_not second.active?
    end
    assert_equal 2, calls.size
    assert_not_equal calls.first[:owner], calls.last[:owner]
    assert(calls.all? { |call| call[:purpose] == :login && call[:locale].to_s == 'en' })
    assert_nil second_session[TwoFactorAuth::SESSION_KEYS[:challenge]]
  end

  test 'restarting password authentication replaces the old provider owner' do
    browser = login_session
    TwilioVerifyService.stubs(:send_verification).returns(successful_send)
    original = TwoFactor::SmsLoginChallenge.new(session: browser, credential: @credential)
    assert_equal :sent, original.ensure_for!(@user)
    TwoFactorAuth.start_authentication(browser, @user)
    replacement = TwoFactor::SmsLoginChallenge.new(session: browser, credential: @credential)
    assert_not replacement.active?
  end

  test 'login resends keep the original immutable provider deadline' do
    freeze_time do
      browser = login_session
      deadline = 10.minutes.from_now.to_i
      TwilioVerifyService.stubs(:send_verification).returns(successful_send(deadline: deadline))
      challenge = TwoFactor::SmsLoginChallenge.new(session: browser, credential: @credential)
      assert_equal :sent, challenge.ensure_for!(@user)
      assert_equal :waiting, challenge.resend_for!(@user)
      travel 31.seconds
      assert_equal :sent, challenge.resend_for!(@user)
      assert_equal deadline, browser[TwoFactorAuth::SESSION_KEYS[:metadata]][:code_expires_at]
      travel 10.minutes
      assert_not challenge.active?
    end
  end

  test 'login send and check use the same explicit provider purpose and owner' do
    browser = login_session
    challenge = TwoFactor::SmsLoginChallenge.new(session: browser, credential: @credential)
    TwilioVerifyService.stubs(:send_verification).returns(successful_send)
    challenge.ensure_for!(@user)
    owner = browser[TwoFactorAuth::SESSION_KEYS[:metadata]][:owner]
    TwilioVerifyService.expects(:check_verification)
                       .with(PHONE, '123456', verification_sid: 'VE_TEST', purpose: :login, owner: owner)
                       .returns(success: true, status: 'approved', valid: true)
    assert challenge.check('123456')[:valid]
  end

  test 'setup without an enrollment authority does not invoke the provider' do
    TwilioVerifyService.expects(:send_verification).never
    challenge = TwoFactor::PendingSmsSetupChallenge.new(session: {}, user: @user, phone_number: PHONE)
    assert_equal false, challenge.prepare!
    assert_not challenge.active_session?
  end

  test 'setup proof cannot move between enrollment sessions or rotated bearers' do
    browser = setup_session
    TwilioVerifyService.stubs(:send_verification).returns(successful_send)
    challenge = TwoFactor::PendingSmsSetupChallenge.new(session: browser, user: @user, phone_number: PHONE)
    assert_equal :sent, challenge.prepare!
    assert challenge.active_session?

    browser[:factor_enrollment_authority]['token_digest'] = Session.digest_token('rotated-token')
    replacement = TwoFactor::PendingSmsSetupChallenge.new(session: browser, user: @user, phone_number: PHONE)
    assert_not replacement.active_session?
    TwilioVerifyService.expects(:check_verification).never
    assert_equal 'expired', replacement.check('123456')[:status]
  end

  test 'setup expiry is capped by the enrollment context and never extended by resends' do
    freeze_time do
      browser = setup_session
      browser[:factor_enrollment_authority]['expires_at'] = 4.minutes.from_now.to_i
      TwilioVerifyService.stubs(:send_verification).returns(successful_send(deadline: 10.minutes.from_now.to_i))
      challenge = TwoFactor::PendingSmsSetupChallenge.new(session: browser, user: @user, phone_number: PHONE)
      assert_equal :sent, challenge.prepare!
      original = browser[TwoFactorAuth::SESSION_KEYS[:metadata]][:code_expires_at]
      travel 31.seconds
      assert_equal :sent, challenge.resend!
      assert_equal original, browser[TwoFactorAuth::SESSION_KEYS[:metadata]][:code_expires_at]
      travel 4.minutes
      assert_not challenge.active_session?
    end
  end

  test 'setup send and check retain their dedicated owner without cache locks or cache hydration' do
    browser = setup_session
    Rails.cache.expects(:read).never
    Rails.cache.expects(:write).never
    Rails.cache.expects(:delete).never
    TwilioVerifyService.stubs(:send_verification).returns(successful_send)
    challenge = TwoFactor::PendingSmsSetupChallenge.new(session: browser, user: @user, phone_number: PHONE)
    assert_equal :sent, challenge.prepare!
    owner = browser[TwoFactorAuth::SESSION_KEYS[:metadata]][:owner]
    TwilioVerifyService.expects(:check_verification)
                       .with(PHONE, '123456', verification_sid: 'VE_TEST', purpose: :setup, owner: owner)
                       .returns(success: true, status: 'approved', valid: true)
    assert challenge.check('123456')[:valid]
    challenge.clear!
    assert_not challenge.active_session?
  end

  private

  def login_session
    {}.tap { |browser| TwoFactorAuth.start_authentication(browser, @user) }
  end

  def setup_session
    { factor_enrollment_authority: {
      'user_id' => @user.id, 'session_id' => 42,
      'token_digest' => Session.digest_token('presented-token'), 'security_version' => @user.security_version,
      'nonce' => SecureRandom.hex(24), 'expires_at' => 10.minutes.from_now.to_i
    } }
  end

  def successful_send(deadline: 10.minutes.from_now.to_i)
    { success: true, verification_sid: 'VE_TEST', status: 'pending', code_expires_at: deadline }
  end
end
