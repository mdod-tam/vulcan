# frozen_string_literal: true

require 'test_helper'

class SmsServiceTest < ActiveSupport::TestCase
  test 'formats ten digit phone numbers for Twilio delivery' do
    assert_equal '+15551234567', SmsService.format_phone_to_e164('555-123-4567')
  end

  test 'preserves already formatted E.164 phone numbers' do
    assert_equal '+15551234567', SmsService.format_phone_to_e164('+15551234567')
  end

  test 'configured SMS uses the provider credentials, sender, normalized recipient and original body' do
    with_twilio_configuration do |config|
      messages = mock('provider_messages')
      messages.expects(:create).with(from: config.fetch(:sms_from_number), to: '+14105550199', body: 'Your proof upload is ready.').returns(true)
      Twilio::REST::Client.expects(:new).with(config.fetch(:account_sid), config.fetch(:auth_token)).returns(stub(messages: messages))

      assert SmsService.send_message('410-555-0199', 'Your proof upload is ready.', action: 'SmsService#proof_resubmission')
    end
  end

  test 'a control turned off while constructing the configured client prevents the final provider handoff' do
    actor = ensure_system_audit_actor!
    messages = mock('provider_messages')
    messages.expects(:create).never
    client = stub(messages: messages)
    construct = lambda do |*|
      EmailDelivery::ControlWriter.set(name: EmailDelivery::CHANNEL_CONTROLS.fetch('sms'), enabled: false,
                                       actor: actor, operation_id: 'sms-final-provider-stop')
      client
    end

    with_twilio_configuration do
      Twilio::REST::Client.stub(:new, construct) do
        error = assert_raises(ApplicationMailer::DeliverySkipped) do
          SmsService.send_message('410-555-0199', 'Do not send after the stop.', action: 'SmsService#proof_resubmission')
        end
        assert_equal 'sms_disabled', error.reason
      end
    end
    control = FeatureFlag.find_by!(name: EmailDelivery::CHANNEL_CONTROLS.fetch('sms'))
    assert_not control.enabled
    event = Event.find_by!(action: EmailDelivery::ControlWriter::AUDIT_ACTION, auditable: control)
    assert_equal actor.id, event.user_id
  end

  test 'delivery failures preserve the provider exception while logging only its class and code' do
    private_detail = 'Private Patient private-sms@example.test at 410-555-0199 token=private-sms-token'
    response = Struct.new(:status_code, :body).new(400, { 'code' => 21_211, 'message' => private_detail })
    error = Twilio::REST::RestError.new(private_detail, response)
    error.set_backtrace(["#{private_detail}:1:in failure"])
    provider_messages = mock('provider_messages')
    provider_messages.expects(:create).raises(error)
    messages = []

    with_twilio_configuration do |config|
      Twilio::REST::Client.expects(:new).with(config.fetch(:account_sid), config.fetch(:auth_token)).returns(stub(messages: provider_messages))
      raised = Rails.logger.stub(:error, ->(message) { messages << message }) do
        assert_raises(Twilio::REST::RestError) do
          SmsService.send_message('410-555-0199', private_detail, sensitive: true, action: 'SmsService#proof_resubmission')
        end
      end
      assert_same error, raised
    end

    assert_includes messages.join, 'Twilio::REST::RestError'
    assert_includes messages.join, 'Twilio error code: 21211'
    %w[Private private-sms@example.test 410-555-0199 private-sms-token].each do |private_value|
      assert_not_includes messages.join, private_value
    end
  end

  private

  def with_twilio_configuration
    original = Rails.application.config.twilio
    config = original.merge(account_sid: 'AC-configured-sms-probe', auth_token: 'test-auth-token', sms_from_number: '+15550000000')
    Rails.application.config.twilio = config
    yield config
  ensure
    Rails.application.config.twilio = original
  end
end
