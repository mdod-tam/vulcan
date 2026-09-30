# frozen_string_literal: true

require 'test_helper'

module EmailDelivery
  class OutboundPolicyTest < ActiveSupport::TestCase
    setup do
      @admin = create(:admin)
      ensure_system_audit_actor!
      @sms = create(:constituent).sms_credentials.create!(phone_number: '555-123-4567', verified_at: Time.current)
      @action = 'ApplicationNotificationsMailer#registration_confirmation'
    end

    test 'All off blocks ordinary messages on every channel' do
      set(ALL_CONTROL, false)
      { @action => %w[email letter], 'SmsService#proof_resubmission' => ['sms'],
        'FaxService#certification_rejected' => ['fax'] }.each do |action, channels|
        context = Policy.capture(mail_action: action, params: { sms_credential_id: @sms.id, phone_number: @sms.phone_number })
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
      context = Policy.capture(mail_action: 'SmsService#proof_resubmission')
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

    test 'SMS emergency stop blocks required verification as well as ordinary SMS' do
      set(CHANNEL_CONTROLS['sms'], false)
      Twilio::REST::Client.expects(:new).never

      assert_raises(ApplicationMailer::DeliverySkipped) do
        SmsService.send_message('555-123-4567', 'Notice', action: 'SmsService#proof_resubmission')
      end
      result = TwilioVerifyService.send_verification(@sms.phone_number, purpose: :login, sms_credential_id: @sms.id)
      assert_not result[:success]
      assert result[:delivery_suppressed]
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

    test 'required actions bypass switches but cannot authorize a different action or channel' do
      [ALL_CONTROL, EmailDelivery.category_control('account_security')].each { |name| set(name, false) }
      Catalog::ESSENTIAL_ACTIONS.each_key do |action|
        context = Policy.capture(mail_action: action, params: { sms_credential_id: @sms.id, phone_number: @sms.phone_number })
        channel = Catalog.channels_for(action).first
        assert Policy.verify_delivery(action, context, channel: channel).allowed?, action
        assert_equal 'delivery_identity_changed', Policy.verify_delivery(@action, context).reason
        assert Policy.verify_delivery(action, context, channel: 'letter').configuration_error?
      end
      test_send = Policy.capture(mail_action: 'AdminTestMailer#test_email', params: { template_name: 'user_mailer_password_reset' })
      assert_not Policy.verify(test_send).allowed?
    end

    test 'All off allows login but blocks adding a new SMS factor' do
      set(ALL_CONTROL, false)
      assert TwilioVerifyService.send_verification(@sms.phone_number, purpose: :login, sms_credential_id: @sms.id)[:success]
      setup = TwilioVerifyService.send_verification('+15551234567', purpose: :setup)
      assert setup[:delivery_suppressed]
      assert_not setup[:verification_sid]
    end

    test 'SMS-only eligibility is rechecked after capture when another factor is added' do
      set(ALL_CONTROL, false)
      context = Policy.capture(mail_action: 'TwoFactor#sms_login', params: { sms_credential_id: @sms.id, phone_number: @sms.phone_number })
      assert Policy.verify(context, channel: :sms).allowed?
      @sms.user.totp_credentials.create!(secret: ROTP::Base32.random_base32, nickname: 'App')
      assert_equal 'all_disabled', Policy.verify(context, channel: :sms).reason
    end

    test 'a passkey or an unverified SMS credential cannot use the exception' do
      set(ALL_CONTROL, false)
      create(:webauthn_credential, user: @sms.user)
      assert TwilioVerifyService.send_verification(@sms.phone_number, purpose: :login, sms_credential_id: @sms.id)[:delivery_suppressed]
      @sms.user.webauthn_credentials.destroy_all
      @sms.update!(verified_at: nil)
      assert TwilioVerifyService.send_verification(@sms.phone_number, purpose: :login, sms_credential_id: @sms.id)[:delivery_suppressed]
    end

    test 'each exception handoff has one audit event with the bypassed controls' do
      set(ALL_CONTROL, false)
      set(EmailDelivery.category_control('account_security'), false)
      assert_difference -> { Event.where(action: 'essential_communication_submitted').count }, 1 do
        assert TwilioVerifyService.send_verification(@sms.phone_number, purpose: :login, sms_credential_id: @sms.id)[:success]
      end
      event = Event.where(action: 'essential_communication_submitted').last
      assert_equal 'TwoFactor#sms_login', event.metadata['mail_action']
      assert_equal [ALL_CONTROL, EmailDelivery.category_control('account_security')], event.metadata['bypassed_controls']
    end

    test 'recovery template display respects the exception and the email emergency stop' do
      set(ALL_CONTROL, false)
      set(EmailDelivery.category_control('account_security'), false)
      assert_equal 'Eligible to send', recovery_email_state
      set(GLOBAL_CONTROL, false)
      assert_equal ControlPanel.reason_text(:global_disabled), recovery_email_state
    end

    test 'recovery template display does not hide missing required controls' do
      FeatureFlag.find_by!(name: ALL_CONTROL).destroy!
      assert_equal ControlPanel.reason_text(:configuration_error), recovery_email_state
      FeatureFlag.create!(name: ALL_CONTROL, enabled: false)
      FeatureFlag.find_by!(name: EmailDelivery.category_control('account_security')).destroy!
      assert_equal ControlPanel.reason_text(:configuration_error), recovery_email_state
    end

    private

    def recovery_email_state
      panel = ControlPanel.new
      pair = panel.pairs.find { |row| row.name == 'user_mailer_password_reset' }
      panel.pair_channel_states(pair).fetch('Email')
    end

    def set(name, enabled)
      ControlWriter.set(name: name, enabled: enabled, actor: @admin, operation_id: SecureRandom.uuid)
    end
  end
end
