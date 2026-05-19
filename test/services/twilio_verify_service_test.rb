# frozen_string_literal: true

require 'test_helper'

class TwilioVerifyServiceTest < ActiveSupport::TestCase
  TwilioErrorResponse = Struct.new(:status_code, :body)

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

  def twilio_error(code:, status_code:)
    Twilio::REST::RestError.new(
      'Verify check failed',
      TwilioErrorResponse.new(status_code, { 'code' => code, 'message' => 'Verify check failed' })
    )
  end

  def stub_verification_check(error)
    verification_checks = mock('verification_checks')
    verification_checks.expects(:create)
                       .with({ verification_sid: 'VEaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', code: '123456' })
                       .raises(error)

    verify_service = mock('verify_service')
    verify_service.stubs(:verification_checks).returns(verification_checks)

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
  end
end
