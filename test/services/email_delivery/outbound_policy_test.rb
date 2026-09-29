# frozen_string_literal: true

require 'test_helper'

module EmailDelivery
  class OutboundPolicyTest < ActiveSupport::TestCase
    setup do
      @admin = create(:admin)
      @action = 'ApplicationNotificationsMailer#registration_confirmation'
    end

    test 'All off blocks every channel including channels saved on' do
      set(ALL_CONTROL, false)
      { @action => %w[email letter], 'SmsService#account_access' => ['sms'],
        'FaxService#certification_rejected' => ['fax'] }.each do |action, channels|
        context = Policy.capture(mail_action: action)
        channels.each do |channel|
          assert_equal 'all_disabled', Policy.verify_delivery(action, context, channel: channel).reason
        end
      end
      assert FeatureFlag.where(name: CHANNEL_CONTROLS.values).all?(&:enabled)
    end

    test 'Email off preserves an originally authorized letter route' do
      set(GLOBAL_CONTROL, false)
      context = Policy.capture(mail_action: @action)

      assert_equal 'global_disabled', Policy.verify(context).reason
      assert Policy.verify(context, channel: :letter).allowed?
      assert Policy.verify_any(@action, context).allowed?
    end

    test 'channel cancellation survives reenable without canceling a sibling channel' do
      context = Policy.capture(mail_action: @action)
      set(CHANNEL_CONTROLS['letter'], false)
      set(CHANNEL_CONTROLS['letter'], true)

      assert_equal 'pending_canceled', Policy.verify(context, channel: :letter).reason
      assert Policy.verify(context).allowed?
      assert Policy.verify(Policy.capture(mail_action: @action), channel: :letter).allowed?
    end

    test 'a request captured with SMS off never gains authorization on reenable' do
      set(CHANNEL_CONTROLS['sms'], false)
      context = Policy.capture(mail_action: 'SmsService#account_access')
      set(CHANNEL_CONTROLS['sms'], true)

      assert_equal 'sms_disabled', Policy.verify(context, channel: :sms).reason
    end

    test 'All off on invalidates every captured route' do
      context = Policy.capture(mail_action: @action)
      set(ALL_CONTROL, false)
      set(ALL_CONTROL, true)

      %w[email letter].each { |channel| assert_equal 'pending_canceled', Policy.verify(context, channel: channel).reason }
    end

    test 'old captures and changed action identities cannot acquire new authorization' do
      context = Policy.capture(mail_action: @action)
      assert_equal 'legacy_context_missing', Policy.verify(context.except('version')).reason
      assert_equal 'delivery_identity_changed', Policy.verify_delivery('UserMailer#password_reset', context).reason
    end

    test 'missing master is a configuration error and a replacement master cancels captured work' do
      context = Policy.capture(mail_action: @action)
      FeatureFlag.find_by!(name: ALL_CONTROL).destroy!
      assert Policy.verify(context).configuration_error?
      FeatureFlag.create!(name: ALL_CONTROL, enabled: true)
      assert_equal 'pending_canceled', Policy.verify(context).reason
    end

    test 'ordinary SMS and Verify test shortcut both obey SMS control' do
      set(CHANNEL_CONTROLS['sms'], false)
      Twilio::REST::Client.expects(:new).never

      assert_raises(ApplicationMailer::DeliverySkipped) do
        SmsService.send_message('555-123-4567', 'Notice', action: 'SmsService#account_access')
      end
      result = TwilioVerifyService.send_verification('+15551234567')
      assert_equal false, result[:success]
      assert result[:delivery_suppressed]
      assert_not result.key?(:verification_sid)
      assert TwilioVerifyService.check_verification('+15551234567', '123456', verification_sid: 'EXISTING')[:valid]
    end

    test 'unknown SMS caller is refused even without provider credentials' do
      assert_raises(ConfigurationError) { SmsService.send_message('555-123-4567', 'Notice') }
    end

    test 'generic flag writers cannot bypass new controls' do
      assert_not FeatureFlag.general.exists?(name: ALL_CONTROL)
      assert_raises(ActiveRecord::RecordInvalid) { FeatureFlag.disable!(ALL_CONTROL) }
      assert FeatureFlag.find_by!(name: ALL_CONTROL).enabled
    end

    private

    def set(name, enabled)
      ControlWriter.set(name: name, enabled: enabled, actor: @admin, operation_id: SecureRandom.uuid)
    end
  end
end
