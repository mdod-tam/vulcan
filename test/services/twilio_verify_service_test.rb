# frozen_string_literal: true

require 'test_helper'

class TwilioVerifyServiceTest < ActiveSupport::TestCase
  TwilioErrorResponse = Struct.new(:status_code, :body)
  TwilioVerificationResponse = Data.define(:sid, :status, :to, :channel)
  TwilioVerificationCheckResponse = Data.define(:status, :to)

  test 'SMS setup configuration errors use SMS guidance in the current locale' do
    FeatureFlag.find_by!(name: EmailDelivery::CHANNEL_CONTROLS.fetch('sms')).destroy!
    TwilioVerifyService.expects(:client).never

    %i[en es].each do |locale|
      I18n.with_locale(locale) do
        result = TwilioVerifyService.send_verification('+15551234567', purpose: :setup)

        assert_not result[:success]
        assert result[:configuration_error]
        assert_not result[:delivery_suppressed]
        assert_equal I18n.t('outbound_delivery.sms_configuration_error'), result[:error]
        assert_not_equal I18n.t('email_delivery.configuration_error'), result[:error]
      end
    end
  end

  test 'verification check params use verification sid when provided' do
    assert_equal(
      { verification_sid: 'VEaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', code: '123456' },
      TwilioVerifyService.send(
        :verification_check_params,
        '123456',
        verification_sid: 'VEaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
      )
    )
  end

  test 'verification check params require verification sid' do
    assert_raises(ArgumentError) do
      TwilioVerifyService.send(:verification_check_params, '123456')
    end
  end

  test 'login and setup sends redact phone logs while preserving the provider destination' do
    phone_number = '555-123-4567'
    destination = '+15551234567'
    credential = create(:constituent).sms_credentials.create!(phone_number: phone_number, verified_at: Time.current)
    verification = TwilioVerificationResponse.new(sid: 'VE_TEST', status: 'pending', to: destination, channel: 'sms')
    verifications = mock('verifications')
    verifications.expects(:create).with(channel: 'sms', to: destination).twice.returns(verification)
    stub_verify_service.stubs(:verifications).returns(verifications)

    logs = capture_rails_logs do
      %i[login setup].each do |purpose|
        result = TwilioVerifyService.send_verification(phone_number, purpose: purpose, sms_credential_id: credential.id)
        assert result[:success]
        assert_equal destination, result[:to]
        assert_equal 'VE_TEST', result[:verification_sid]
      end
    end

    assert_includes logs, 'Sending verification to [REDACTED_PHONE]'
    assert_private_phone_logs(logs, phone_number, destination)
  end

  test 'verification check redacts phone logs while preserving the sid and code sent to the provider' do
    destination = '+15551234567'
    verification_checks = mock('verification_checks')
    verification_checks.expects(:create)
                       .with(verification_sid: 'VE_CHECK_TEST', code: '654321')
                       .returns(TwilioVerificationCheckResponse.new(status: 'approved', to: destination))
    stub_verify_service.stubs(:verification_checks).returns(verification_checks)

    logs = capture_rails_logs do
      result = TwilioVerifyService.check_verification('555-123-4567', '654321', verification_sid: 'VE_CHECK_TEST')
      assert result[:success]
      assert result[:valid]
      assert_equal destination, result[:to]
    end

    assert_includes logs, 'phone [REDACTED_PHONE]'
    assert_private_phone_logs(logs, '555-123-4567', destination)
    assert_not_includes logs, '654321'
  end

  test 'test mode keeps phone numbers and verification codes out of logs' do
    TwilioVerifyService.expects(:client).never

    logs = capture_rails_logs do
      send_result = TwilioVerifyService.send_verification('555-123-4567', purpose: :setup)
      check_result = TwilioVerifyService.check_verification('555-123-4567', '123456', verification_sid: send_result[:verification_sid])
      assert send_result[:success]
      assert_equal '555-123-4567', send_result[:to]
      assert check_result[:valid]
    end

    assert_includes logs, 'Simulating verification send to [REDACTED_PHONE]'
    assert_private_phone_logs(logs, '555-123-4567', '+15551234567')
    assert_not_includes logs, '123456'
  end

  test 'provider send errors redact echoed phone numbers and secure URLs from logs' do
    error = twilio_error(code: 20_400, status_code: 400, message: private_error_message)
    verifications = mock('verifications')
    verifications.expects(:create).with(channel: 'sms', to: '+15551234567').raises(error)
    stub_verify_service.stubs(:verifications).returns(verifications)

    logs = capture_rails_logs do
      result = TwilioVerifyService.send_verification('555-123-4567', purpose: :setup)
      assert_not result[:success]
      assert_equal 20_400, result[:error_code]
      assert_private_error_logs(result[:error])
    end

    assert_private_error_logs(logs)
  end

  test 'provider check errors redact echoed phone numbers and secure URLs from logs' do
    error = twilio_error(code: 60_200, status_code: 400, message: private_error_message)
    stub_verification_check(error)

    logs = capture_rails_logs do
      result = TwilioVerifyService.check_verification('555-123-4567', '123456', verification_sid: 'VEaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')
      assert result[:success]
      assert_not result[:valid]
      assert_equal 'invalid_input', result[:status]
      assert_private_error_logs(result[:error])
      TwoFactorAuth.log_verification_failure(42, :sms, result[:error])
    end

    assert_private_error_logs(logs)
  end

  test 'unexpected send errors sanitize both the message and backtrace' do
    error = StandardError.new(private_error_message)
    error.set_backtrace([private_error_message])
    verifications = mock('verifications')
    verifications.expects(:create).with(channel: 'sms', to: '+15551234567').raises(error)
    stub_verify_service.stubs(:verifications).returns(verifications)

    logs = capture_rails_logs do
      result = TwilioVerifyService.send_verification('555-123-4567', purpose: :setup)
      assert_not result[:success]
      assert_private_error_logs(result[:error])
    end

    assert_includes logs, '[TwilioVerify] Backtrace:'
    assert_private_error_logs(logs)
  end

  test 'unexpected check errors sanitize the message' do
    stub_verification_check(StandardError.new(private_error_message))

    logs = capture_rails_logs do
      result = TwilioVerifyService.check_verification('555-123-4567', '123456', verification_sid: 'VEaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')
      assert_not result[:success]
      assert_private_error_logs(result[:error])
      TwoFactorAuth.log_verification_failure(42, :sms, result[:error])
    end

    assert_private_error_logs(logs)
  end

  test 'maps Twilio 60200 to invalid input without terminal failure' do
    error = twilio_error(code: 60_200, status_code: 400)
    stub_verification_check(error)

    result = TwilioVerifyService.check_verification(
      '555-123-4567',
      '123456',
      verification_sid: 'VEaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    )

    assert result[:success]
    assert_equal 'invalid_input', result[:status]
    assert_not result[:valid]
  end

  test 'maps Twilio 404 to not found for sid checks' do
    error = twilio_error(code: 20_404, status_code: 404)
    stub_verification_check(error)

    result = TwilioVerifyService.check_verification(
      '555-123-4567',
      '123456',
      verification_sid: 'VEaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    )

    assert result[:success]
    assert_equal 'not_found', result[:status]
    assert_not result[:valid]
  end

  private

  def twilio_error(code:, status_code:, message: 'Verify check failed')
    Twilio::REST::RestError.new(
      'Verify check failed',
      TwilioErrorResponse.new(status_code, { 'code' => code, 'message' => message })
    )
  end

  def stub_verification_check(error)
    verification_checks = mock('verification_checks')
    verification_checks.expects(:create)
                       .with(verification_sid: 'VEaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', code: '123456')
                       .raises(error)

    stub_verify_service.stubs(:verification_checks).returns(verification_checks)
  end

  def stub_verify_service
    verify_service = mock('verify_service')

    verify_v2 = mock('verify_v2')
    verify_v2.stubs(:services).with('VA_TEST').returns(verify_service)

    verify_api = mock('verify_api')
    verify_api.stubs(:v2).returns(verify_v2)

    client = mock('twilio_client')
    client.stubs(:verify).returns(verify_api)

    TwilioVerifyService.stubs(:test_mode?).returns(false)
    TwilioVerifyService.stubs(:verify_configured?).returns(true)
    TwilioVerifyService.stubs(:verify_service_sid).returns('VA_TEST')
    TwilioVerifyService.stubs(:client).returns(client)
    verify_service
  end

  def assert_private_phone_logs(logs, *phone_numbers)
    phone_numbers.each { |phone_number| assert_not_includes logs, phone_number }
    assert_not_includes logs, '5551234567'
  end

  def private_error_message
    'provider echoed 555-123-4567 / +15551234567 / https://example.test/verify?token=private-token'
  end

  def assert_private_error_logs(logs)
    assert_private_phone_logs(logs, '555-123-4567', '+15551234567')
    assert_not_includes logs, 'https://example.test/verify'
    assert_not_includes logs, 'private-token'
    assert_includes logs, '[REDACTED_PHONE]'
    assert_includes logs, '[REDACTED_URL]'
  end
end
