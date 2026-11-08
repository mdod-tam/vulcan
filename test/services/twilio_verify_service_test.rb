# frozen_string_literal: true

require 'test_helper'

class TwilioVerifyServiceTest < ActiveSupport::TestCase
  TwilioErrorResponse = Struct.new(:status_code, :body)
  PHONE = '555-123-4567'
  DESTINATION = '+15551234567'
  SID = 'VEaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'

  setup do
    @owner = SecureRandom.hex(24)
    @verifications = mock('verifications')
    @checks = mock('verification_checks')
    provider = mock('verify_service')
    provider.stubs(:verifications).returns(@verifications)
    provider.stubs(:verification_checks).returns(@checks)
    TwilioVerifyService.stubs(:provider_service).returns(provider)
    TwilioVerifyService.stubs(:test_mode?).returns(false)
    TwilioVerifyService.stubs(:verify_configured?).returns(true)
    TwilioVerifyService.stubs(:verify_service_sid).returns('VA_TEST')
  end

  test 'SMS configuration errors use SMS guidance in each supported locale' do
    FeatureFlag.find_by!(name: EmailDelivery::CHANNEL_CONTROLS.fetch('sms')).destroy!
    @verifications.expects(:create).never

    %i[en es].each do |locale|
      I18n.with_locale(locale) do
        result = send_code
        assert_not result[:success]
        assert result[:configuration_error]
        assert_not result[:delivery_suppressed]
        assert_equal I18n.t('outbound_delivery.sms_configuration_error'), result[:error]
      end
    end
  end

  test 'a send preserves normalized provider destination and passes supported locale without logging contacts' do
    @verifications.expects(:create).with(channel: 'sms', to: DESTINATION, locale: 'es').returns(provider_send)
    logs = capture_rails_logs do
      result = send_code(locale: 'es')
      assert result[:success]
      assert_equal DESTINATION, result[:to]
      assert_equal SID, result[:verification_sid]
      assert_operator result[:code_expires_at], :<=, 10.minutes.from_now.to_i
    end
    assert_private_logs(logs)
  end

  test 'a resend retains the original provider validity window and owner' do
    freeze_time do
      original = Time.current
      @verifications.expects(:create).with(channel: 'sms', to: DESTINATION, locale: 'en')
                    .twice.returns(provider_send(date_created: original))
      first = send_code
      travel 31.seconds
      resent = send_code
      assert first[:success]
      assert resent[:success]
      assert_equal first[:verification_sid], resent[:verification_sid]
      assert_equal first[:code_expires_at], resent[:code_expires_at]
    end
  end

  test 'a configured longer provider lifetime keeps another context out after local entry expires' do
    original_config = Rails.application.config.twilio
    Rails.application.config.twilio = original_config.merge(verify_token_lifetime_seconds: '1200')
    freeze_time do
      start_provider_challenge
      attempt = SmsVerificationAttempt.sole
      assert_operator attempt.ownership_expires_at, :>=, 20.minutes.from_now
      travel 10.minutes + 1.second
      @verifications.expects(:create).never
      @checks.expects(:create).never
      assert_not send_code(purpose: :contact_change, owner: 'other-context')[:success]
      assert_not check_code[:valid]
      assert_nil attempt.reload.finished_at
    end
  ensure
    Rails.application.config.twilio = original_config
  end

  test 'invalid provider lifetime prevents reservation and transport' do
    original_config = Rails.application.config.twilio
    Rails.application.config.twilio = original_config.merge(verify_token_lifetime_seconds: 'invalid')
    @verifications.expects(:create).never
    assert_no_difference 'SmsVerificationAttempt.count' do
      assert_not send_code[:success]
    end
  ensure
    Rails.application.config.twilio = original_config
  end

  test 'the real SDK client uses the bounded HTTP adapter for a public send' do
    original_client = TwilioVerifyService.instance_variable_get(:@client)
    TwilioVerifyService.instance_variable_set(:@client, nil)
    TwilioVerifyService.unstub(:provider_service)
    transport = Twilio::HTTP::Client.new(timeout: 15)
    default_transport = Twilio::HTTP::Client.new
    Twilio::HTTP::Client.expects(:new).with { |*arguments| arguments.empty? }.returns(default_transport)
    Twilio::HTTP::Client.expects(:new).with(timeout: 15).returns(transport)
    payload = provider_send.merge(date_created: Time.current.iso8601)
    transport.expects(:request).returns(Twilio::Response.new(201, payload.to_json))
    assert send_code[:success]
    assert_operator transport.timeout * 2, :<, SmsVerificationAttempt::CALL_TIMEOUT
  ensure
    TwilioVerifyService.instance_variable_set(:@client, original_client)
  end

  test 'another browser or purpose cannot adopt an in-flight provider verification' do
    start_provider_challenge
    @verifications.expects(:create).never
    @checks.expects(:create).never

    assert_not send_code(owner: 'another-browser')[:success]
    assert_not send_code(purpose: :contact_change)[:success]
    assert_not check_code(owner: 'another-browser')[:valid]
    assert_not check_code(purpose: :contact_change)[:valid]
    assert_equal 0, SmsVerificationAttempt.sole.checks_count
  end

  test 'checking by the stored SID validates the provider binding and persists approval' do
    start_provider_challenge
    @checks.expects(:create).with(verification_sid: SID, code: '654321').returns(provider_check(status: 'approved'))

    logs = capture_rails_logs do
      result = check_code(code: '654321')
      assert result[:success]
      assert result[:valid]
      assert_equal 'approved', result[:status]
      assert SmsVerificationAttempt.find(result[:receipt_id]).approved_at
    end
    assert_private_logs(logs)
    assert_not_includes logs, '654321'
  end

  test 'a successful HTTP check with pending status is not ownership proof' do
    start_provider_challenge
    @checks.expects(:create).with(verification_sid: SID, code: '123456').returns(provider_check(status: 'pending'))
    result = check_code
    assert result[:success]
    assert_not result[:valid]
    assert_equal 'pending', result[:status]
    assert_nil SmsVerificationAttempt.sole.approved_at
  end

  %i[to service_sid channel sid].each do |attribute|
    test "a provider check with a mismatched #{attribute} cannot approve" do
      start_provider_challenge
      @checks.expects(:create).returns(provider_check(status: 'approved').merge(attribute => 'wrong'))
      result = check_code
      assert_not result[:success]
      assert_not result[:valid]
      assert_nil SmsVerificationAttempt.sole.approved_at
    end
  end

  test 'unknown SID and malformed code are refused before provider I/O' do
    start_provider_challenge
    @checks.expects(:create).never
    assert_not check_code(verification_sid: 'another-sid')[:valid]
    assert_not check_code(code: 'invalid')[:valid]
    assert_raises(ArgumentError) do
      TwilioVerifyService.check_verification(PHONE, '123456', purpose: :setup, owner: @owner)
    end
  end

  test 'a later 404 never substitutes for a durable approved receipt' do
    start_provider_challenge
    @checks.expects(:create).raises(twilio_error(code: 20_404, status_code: 404))
    result = check_code
    assert_not result[:success]
    assert_not result[:valid]
    assert_nil SmsVerificationAttempt.sole.approved_at
  end

  test 'test mode also requires owned live state and keeps phone numbers and codes out of logs' do
    TwilioVerifyService.stubs(:test_mode?).returns(true)
    TwilioVerifyService.expects(:client).never
    logs = capture_rails_logs do
      sent = send_code
      assert sent[:success]
      assert check_code(verification_sid: sent[:verification_sid])[:valid]
      assert_not check_code(verification_sid: sent[:verification_sid])[:valid]
    end
    assert_private_logs(logs)
    assert_not_includes logs, '123456'
  end

  test 'send errors expose only generic guidance and retain the uncertain reservation' do
    error = StandardError.new(private_error_message)
    error.set_backtrace([private_error_message])
    @verifications.expects(:create).raises(error)
    logs = capture_rails_logs do
      result = send_code
      assert_not result[:success]
      assert_private_logs(result[:error])
    end
    assert_private_logs(logs)
    assert_includes logs, 'StandardError'
    assert SmsVerificationAttempt.sole.sending_until
    assert_nil SmsVerificationAttempt.sole.finished_at
  end

  test 'provider check errors never log echoed contacts or tokens and never approve' do
    start_provider_challenge
    @checks.expects(:create).raises(twilio_error(code: 60_200, status_code: 400, message: private_error_message))
    logs = capture_rails_logs do
      result = check_code
      assert_not result[:valid]
      assert_private_logs(result[:error])
    end
    assert_private_logs(logs)
    assert_equal 1, SmsVerificationAttempt.sole.checks_count
    assert_nil SmsVerificationAttempt.sole.approved_at
  end

  private

  def send_code(purpose: :setup, owner: @owner, locale: 'en')
    TwilioVerifyService.send_verification(PHONE, purpose: purpose, owner: owner, locale: locale)
  end

  def check_code(code: '123456', verification_sid: SID, purpose: :setup, owner: @owner)
    TwilioVerifyService.check_verification(PHONE, code, verification_sid: verification_sid, purpose: purpose, owner: owner)
  end

  def start_provider_challenge
    @verifications.expects(:create).with(channel: 'sms', to: DESTINATION, locale: 'en').returns(provider_send)
    result = send_code
    assert result[:success], result.inspect
  end

  def provider_send(date_created: Time.current)
    { sid: SID, status: 'pending', to: DESTINATION, channel: 'sms', service_sid: 'VA_TEST', date_created: date_created }
  end

  def provider_check(status:)
    { sid: SID, status: status, to: DESTINATION, channel: 'sms', service_sid: 'VA_TEST' }
  end

  def twilio_error(code:, status_code:, message: 'Verify request failed')
    Twilio::REST::RestError.new('Verify request failed', TwilioErrorResponse.new(status_code, { 'code' => code, 'message' => message }))
  end

  def private_error_message
    'provider echoed 555-123-4567 / +15551234567 / https://example.test/verify?token=private-token'
  end

  def assert_private_logs(text)
    [PHONE, DESTINATION, '5551234567', 'https://example.test/verify', 'private-token'].each do |secret|
      assert_not_includes text.to_s, secret
    end
  end
end
