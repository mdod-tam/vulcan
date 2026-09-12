# frozen_string_literal: true

require 'test_helper'

module Applications
  class RequestProviderInfoTest < ActiveSupport::TestCase
    include ActiveSupport::Testing::TimeHelpers

    setup do
      @actor = create(:admin)
      @application = create(:application)
      @mailer_delivery = mock('provider-info-mailer-delivery')
      @mailer_delivery.stubs(:deliver_later).returns(true)
      @mailer_delivery.stubs(:deliver_now).returns(true)
      ApplicationNotificationsMailer.stubs(:provider_info_requested).returns(@mailer_delivery)
    end

    test 'unsupported SMS delivery locale falls back without revoking the request' do
      @application.user.update!(locale: 'unsupported', phone_type: 'text')
      SmsService.expects(:send_message).with do |phone, body, **options|
        phone == @application.user.phone && body.include?('provider') && options[:sensitive]
      end.returns(true)

      result = RequestProviderInfo.new(application: @application, actor: @actor,
                                       channel_overrides: { @application.user_id => 'sms' }).call

      assert_predicate result, :success?
      assert_predicate result.data.fetch(:secure_request_forms).first.reload, :active?
    end

    private

    # Paper context permits a constituent with no digital contact.
    def build_address_only_constituent
      Current.paper_context = true
      create(:constituent, email: nil, phone: nil, communication_preference: 'letter')
    ensure
      Current.reset
    end

    # Active dependent with guardian-owned contact and address. Returns [guardian, dependent, application].
    def build_dependent_routed_through_guardian(guardian_attrs = {})
      guardian = create(:constituent, {
        email: "guardian.owner.#{SecureRandom.hex(4)}@example.com"
      }.merge(guardian_attrs))
      dependent = create(
        :constituent,
        email: "dependent.owner.#{SecureRandom.hex(4)}@system.matvulcan.local",
        dependent_email: guardian.email
      )
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent,
                                     relationship_type: 'Parent')
      application = create(:application, user: dependent, managing_guardian: guardian)
      [guardian, dependent, application]
    end

    test 'creates one active request and refuses a duplicate during cooldown' do
      first_result = RequestProviderInfo.new(application: @application, actor: @actor).call
      second_result = RequestProviderInfo.new(application: @application, actor: @actor).call

      assert_predicate first_result, :success?
      assert_not second_result.success?
      assert_equal 1, SecureRequestForm.open_provider_info_for_recipient(
        application_id: @application.id,
        recipient_id: @application.user_id
      ).count
    end

    test 'email delivery sends immediately so raw bearer URL is not persisted in a mailer job' do
      @mailer_delivery.expects(:deliver_now).returns(true)

      result = RequestProviderInfo.new(application: @application, actor: @actor).call

      assert_predicate result, :success?
    end

    test 'issued provider info request appears in application audit logs' do
      result = RequestProviderInfo.new(application: @application, actor: @actor).call

      assert_predicate result, :success?
      notification = Notification.find_by!(
        notifiable: @application,
        action: 'provider_info_requested',
        recipient: @application.user
      )

      with_mocked_attachments do
        logs = AuditLogBuilder.new(@application).build_deduplicated_audit_logs
        assert_includes logs, notification
      end
    end

    test 'default dependent provider info request follows guardian effective email path' do
      guardian = create(:constituent, email: "guardian.provider.#{SecureRandom.hex(3)}@example.com")
      dependent = create(
        :constituent,
        email: "dependent.provider.#{SecureRandom.hex(3)}@system.matvulcan.local",
        dependent_email: guardian.email
      )
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent, relationship_type: 'Parent')
      application = create(:application, user: dependent, managing_guardian: guardian)

      result = RequestProviderInfo.new(application: application, actor: @actor).call

      assert_predicate result, :success?
      form = result.data.fetch(:secure_request_forms).first
      assert_equal guardian, form.recipient
      assert_equal 'guardian', form.recipient_role
      assert_equal guardian.email, form.recipient_email
      assert_equal guardian, Notification.find_by!(notifiable: application, action: 'provider_info_requested').recipient
    end

    test 'default dependent provider info request follows separate dependent effective email path' do
      guardian = create(:constituent, email: "guardian.provider.#{SecureRandom.hex(3)}@example.com")
      dependent_email = "dependent.provider.#{SecureRandom.hex(3)}@example.com"
      dependent = create(:constituent, email: dependent_email, dependent_email: dependent_email)
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent, relationship_type: 'Parent')
      application = create(:application, user: dependent, managing_guardian: guardian)

      result = RequestProviderInfo.new(application: application, actor: @actor).call

      assert_predicate result, :success?
      form = result.data.fetch(:secure_request_forms).first
      assert_equal dependent, form.recipient
      assert_equal 'constituent', form.recipient_role
      assert_equal dependent_email, form.recipient_email
      assert_equal dependent, Notification.find_by!(notifiable: application, action: 'provider_info_requested').recipient
    end

    test 'an unrelated inactive guardian does not block issuance to an eligible selected recipient' do
      active_guardian = create(:constituent)
      inactive_guardian = create(:constituent, status: :inactive)
      create(:guardian_relationship, guardian_user: active_guardian, dependent_user: @application.user)
      create(:guardian_relationship, guardian_user: inactive_guardian, dependent_user: @application.user)
      @application.update!(managing_guardian: active_guardian)

      result = RequestProviderInfo.new(
        application: @application,
        actor: @actor,
        recipient_ids: [@application.user_id]
      ).call

      assert_predicate result, :success?
      assert_equal [@application.user_id], result.data.fetch(:secure_request_forms).map(&:recipient_id)
    end

    test 'an inactive selected guardian fails closed without issuing a request' do
      inactive_guardian = create(:constituent, status: :inactive)
      create(:guardian_relationship, guardian_user: inactive_guardian, dependent_user: @application.user)
      @application.update!(managing_guardian: inactive_guardian)

      result = assert_no_difference('SecureRequestForm.count') do
        RequestProviderInfo.new(
          application: @application,
          actor: @actor,
          recipient_ids: [inactive_guardian.id]
        ).call
      end

      assert_not result.success?
      assert_equal I18n.t('applications.provider_info.messages.recipient_no_longer_eligible'), result.message
    end

    test 'alternate contact is not a provider info recipient' do
      application = create(
        :application,
        alternate_contact_name: 'Helpful Person',
        alternate_contact_email: 'alternate.provider@example.com',
        alternate_contact_phone: '410-555-0199'
      )

      result = RequestProviderInfo.new(application: application, actor: @actor).call

      assert_predicate result, :success?
      assert_equal [application.user], result.data.fetch(:secure_request_forms).map(&:recipient)
      assert_no_difference('SecureRequestForm.count') do
        failure_result = RequestProviderInfo.new(
          application: application,
          actor: @actor,
          recipient_ids: [0]
        ).call
        assert_not failure_result.success?
      end
    end

    test 'sms request keeps NotificationService channel compatible while recording requested channel' do
      @application.user.update!(phone_type: 'text', communication_preference: 'email')
      SmsService.stubs(:send_message).returns(true)

      result = RequestProviderInfo.new(
        application: @application,
        actor: @actor,
        channel_overrides: { @application.user_id => 'sms' }
      ).call

      assert_predicate result, :success?
      secure_request_form = result.data.fetch(:secure_request_forms).first
      notification = Notification.find_by!(
        notifiable: @application,
        action: 'provider_info_requested',
        recipient: @application.user
      )
      assert_predicate secure_request_form, :recipient_channel_sms?
      assert_equal 'email', notification.metadata.fetch('channel')
      assert_equal 'sms', notification.metadata.fetch('recipient_channel')
      assert_equal 'sms', notification.metadata.fetch('requested_recipient_channel')
    end

    test 'letter delivery queues a PrintQueueItem via the mailer' do
      @application.user.update!(communication_preference: 'letter')
      ApplicationNotificationsMailer.unstub(:provider_info_requested)

      result = assert_difference('PrintQueueItem.count', 1) do
        RequestProviderInfo.new(application: @application, actor: @actor).call
      end

      assert_predicate result, :success?
      secure_request_form = result.data.fetch(:secure_request_forms).first
      assert_predicate secure_request_form, :recipient_channel_letter?

      print_item = PrintQueueItem.last
      assert_equal 'provider_info_requested', print_item.letter_type
      assert_equal @application.id, print_item.application_id
      assert_equal @application.user_id, print_item.constituent_id
    end

    test 'delivery failure returns a clean result after revoking the undeliverable request' do
      @mailer_delivery.stubs(:deliver_now).raises(StandardError, 'smtp down')
      Rails.error.stubs(:report) if Rails.respond_to?(:error)

      result = RequestProviderInfo.new(application: @application, actor: @actor).call

      assert_not result.success?
      assert_equal I18n.t('applications.provider_info.messages.delivery_failed', locale: @actor.effective_locale),
                   result.message
      assert_equal 0, SecureRequestForm.open_provider_info_for_recipient(
        application_id: @application.id,
        recipient_id: @application.user_id
      ).count
      assert_predicate result.data.fetch(:secure_request_forms).first.reload, :revoked?
      assert_equal true, result.data.fetch(:delivery_error)
      assert_equal [@application.user_id], result.data.fetch(:failed_recipient_ids)
      assert_equal ['email'], result.data.fetch(:failed_recipient_channels)
      assert_equal 'StandardError', result.data.fetch(:delivery_failures).first.fetch(:error_class)
    end

    test 'delivery error reporting redacts secure provider info urls' do
      raw_url = 'https://example.test/secure_provider_info_form?token=raw-provider-token'
      @mailer_delivery.stubs(:deliver_now).raises(StandardError, "smtp rendered #{raw_url}")

      if Rails.respond_to?(:error)
        Rails.error.expects(:report).with do |reported_error, handled:, context:|
          handled == true &&
            reported_error.message == 'smtp rendered [REDACTED_URL]' &&
            reported_error.message.exclude?(raw_url) &&
            reported_error.message.exclude?('raw-provider-token') &&
            context[:error_class] == 'StandardError' &&
            context[:secure_request_form_ids].present?
        end
      end

      result = RequestProviderInfo.new(application: @application, actor: @actor).call

      assert_not result.success?
    end

    test 'delivery failure for one recipient does not skip later recipients' do
      guardian = create(:constituent)
      create(:guardian_relationship, dependent_user: @application.user, guardian_user: guardian)
      delivery = Object.new
      delivery.define_singleton_method(:delivery_attempts) { @delivery_attempts ||= 0 }
      delivery.define_singleton_method(:deliver_now) do
        @delivery_attempts ||= 0
        @delivery_attempts += 1
        raise StandardError, 'smtp down' if @delivery_attempts == 1

        true
      end
      ApplicationNotificationsMailer.stubs(:provider_info_requested).returns(delivery)
      Rails.error.stubs(:report) if Rails.respond_to?(:error)

      result = RequestProviderInfo.new(
        application: @application,
        actor: @actor,
        recipient_ids: [@application.user_id, guardian.id]
      ).call

      assert_not result.success?
      assert_equal 2, delivery.delivery_attempts
      assert_equal [@application.user_id], result.data.fetch(:failed_recipient_ids)
      assert_equal 2, result.data.fetch(:secure_request_forms).size
      failed_form = result.data.fetch(:secure_request_forms).find { |form| form.recipient_id == @application.user_id }
      delivered_form = result.data.fetch(:secure_request_forms).find { |form| form.recipient_id == guardian.id }
      assert_predicate failed_form.reload, :revoked?
      assert_predicate delivered_form.reload, :active?
    end

    test 'multi-recipient issuance rolls back entirely when one candidate hits cooldown' do
      guardian = create(:constituent)
      create(:guardian_relationship, dependent_user: @application.user, guardian_user: guardian)
      @application.update!(managing_guardian_id: guardian.id)

      first_result = RequestProviderInfo.new(
        application: @application,
        actor: @actor,
        recipient_ids: [guardian.id]
      ).call
      assert_predicate first_result, :success?

      multi_result = assert_no_difference(['SecureRequestForm.count', 'Notification.count']) do
        RequestProviderInfo.new(
          application: @application,
          actor: @actor,
          recipient_ids: [@application.user_id, guardian.id]
        ).call
      end

      assert_not multi_result.success?
      assert_match(/minute/, multi_result.message)

      solo_result = RequestProviderInfo.new(
        application: @application,
        actor: @actor,
        recipient_ids: [@application.user_id]
      ).call
      assert_predicate solo_result, :success?
    end

    test 'staff resend respects the same cooldown as initial issuance' do
      original_result = RequestProviderInfo.new(application: @application, actor: @actor).call
      original_request = original_result.data.fetch(:secure_request_forms).first

      resend_result = RequestProviderInfo.new(
        application: @application,
        actor: @actor,
        resend_of: original_request
      ).call

      assert_not resend_result.success?
      assert_predicate original_request.reload, :status_sent?
      assert_equal 1, SecureRequestForm.open_provider_info_for_recipient(
        application_id: @application.id,
        recipient_id: @application.user_id
      ).count
    end

    test 'staff resend after cooldown revokes the prior active link and creates a replacement' do
      original_result = RequestProviderInfo.new(application: @application, actor: @actor).call
      original_request = original_result.data.fetch(:secure_request_forms).first

      resend_result = nil
      travel_to original_request.sent_at + 2.hours do
        resend_result = RequestProviderInfo.new(
          application: @application,
          actor: @actor,
          resend_of: original_request
        ).call
      end

      assert_predicate resend_result, :success?
      assert_predicate original_request.reload, :revoked?
      assert_equal 1, SecureRequestForm.open_provider_info_for_recipient(
        application_id: @application.id,
        recipient_id: @application.user_id
      ).count
    end

    test 'manually revoked request does not block immediate replacement' do
      original_result = RequestProviderInfo.new(application: @application, actor: @actor).call
      original_request = original_result.data.fetch(:secure_request_forms).first
      original_request.revoke!(actor: @actor, reason: :manual_revocation)

      result = assert_difference('SecureRequestForm.count', 1) do
        RequestProviderInfo.new(application: @application, actor: @actor).call
      end

      assert_predicate result, :success?
      assert_predicate original_request.reload, :revoked?
      assert_equal 1, SecureRequestForm.open_provider_info_for_recipient(
        application_id: @application.id,
        recipient_id: @application.user_id
      ).count
    end

    test 'public recovery returns a neutral success during cooldown without creating a replacement' do
      original_result = RequestProviderInfo.new(application: @application, actor: @actor).call
      original_request = original_result.data.fetch(:secure_request_forms).first

      recovery_result = RequestProviderInfo.new(
        application: @application,
        actor: @actor,
        resend_of: original_request,
        public_recovery: true
      ).call

      assert_predicate recovery_result, :success?
      assert_predicate original_request.reload, :status_sent?
      assert_equal 1, SecureRequestForm.open_provider_info_for_recipient(
        application_id: @application.id,
        recipient_id: @application.user_id
      ).count
    end

    test 'auto-repairs managing_guardian_id when exactly one guardian relationship exists' do
      dependent = create(:constituent)
      guardian = create(:constituent)
      application = create(:application, user: dependent)
      create(:guardian_relationship, dependent_user: dependent, guardian_user: guardian)

      assert_nil application.managing_guardian_id

      result = RequestProviderInfo.new(application: application, actor: @actor).call

      assert_predicate result, :success?
      assert_equal guardian.id, application.reload.managing_guardian_id
    end

    test 'blocks issuance with needs_managing_guardian when multiple guardians exist and none is designated' do
      dependent = create(:constituent)
      application = create(:application, user: dependent)
      guardian_a = create(:constituent)
      guardian_b = create(:constituent)
      create(:guardian_relationship, dependent_user: dependent, guardian_user: guardian_a)
      create(:guardian_relationship, dependent_user: dependent, guardian_user: guardian_b)

      result = assert_no_difference('SecureRequestForm.count') do
        RequestProviderInfo.new(application: application, actor: @actor).call
      end

      assert_not result.success?
      assert_equal I18n.t!('applications.provider_info.messages.needs_managing_guardian'),
                   result.message
      assert_nil application.reload.managing_guardian_id
    end

    test 'needs_managing_guardian failure message is translated into Spanish for Spanish-locale admin' do
      spanish_admin = create(:admin, locale: 'es')
      dependent = create(:constituent)
      application = create(:application, user: dependent)
      guardian_a = create(:constituent)
      guardian_b = create(:constituent)
      create(:guardian_relationship, dependent_user: dependent, guardian_user: guardian_a)
      create(:guardian_relationship, dependent_user: dependent, guardian_user: guardian_b)

      result = RequestProviderInfo.new(application: application, actor: spanish_admin).call

      assert_not result.success?
      assert_equal I18n.t!('applications.provider_info.messages.needs_managing_guardian', locale: :es),
                   result.message
    end

    test 'multi-recipient issuance assigns the same request_batch_id to all created forms' do
      guardian = create(:constituent)
      create(:guardian_relationship, dependent_user: @application.user, guardian_user: guardian)

      result = RequestProviderInfo.new(
        application: @application,
        actor: @actor,
        recipient_ids: [@application.user_id, guardian.id]
      ).call

      assert_predicate result, :success?
      forms = result.data.fetch(:secure_request_forms)
      assert_equal 2, forms.size
      batch_ids = forms.map(&:request_batch_id).uniq
      assert_equal 1, batch_ids.size, 'All forms from the same issuance must share one request_batch_id'
    end

    test 'resend cooldown for recipient A does not block recipient B from receiving their own resend' do
      guardian = create(:constituent)
      create(:guardian_relationship, dependent_user: @application.user, guardian_user: guardian)

      applicant_result = RequestProviderInfo.new(
        application: @application,
        actor: @actor,
        recipient_ids: [@application.user_id]
      ).call
      assert_predicate applicant_result, :success?

      guardian_result = RequestProviderInfo.new(
        application: @application,
        actor: @actor,
        recipient_ids: [guardian.id]
      ).call

      assert_predicate guardian_result, :success?
      assert_equal 1, SecureRequestForm.open_provider_info_for_recipient(
        application_id: @application.id,
        recipient_id: guardian.id
      ).count
    end

    test 'raw bearer token does not appear in Notification metadata after issuance' do
      sentinel_token = 'SENTINEL_TOKEN_MUST_NOT_LEAK_IN_METADATA'
      SecureRequestForm.stubs(:generate_public_token).returns(sentinel_token)

      result = RequestProviderInfo.new(application: @application, actor: @actor).call
      assert_predicate result, :success?

      notification = Notification.find_by!(
        notifiable: @application,
        action: 'provider_info_requested',
        recipient: @application.user
      )
      metadata_json = notification.metadata.to_json

      assert_not_includes metadata_json, sentinel_token,
                          'Raw bearer token must not appear in Notification metadata'
      assert_not_includes metadata_json, "token=#{sentinel_token}",
                          'Full secure URL must not appear in Notification metadata'
    end

    test 'issuance does not create a custom secure_link_sent audit event beyond the notification record' do
      # AuditLogBuilder already includes the provider_info_requested notification.
      # A secure_link_sent Event would duplicate the issuance audit.
      assert_no_difference -> { Event.where(action: 'secure_link_sent').count } do
        result = RequestProviderInfo.new(application: @application, actor: @actor).call
        assert_predicate result, :success?
      end
    end

    test 'secure_url_for raises when the configured host is blank in production' do
      Rails.env.stubs(:production?).returns(true)
      Rails.application.config.action_mailer.stubs(:default_url_options).returns({ host: '' })

      service = RequestProviderInfo.new(application: @application, actor: @actor)

      assert_raises(ArgumentError) { service.send(:secure_url_for, 'some-token') }
    end

    test 'secure_url_for raises when the configured host is example.com in production' do
      Rails.env.stubs(:production?).returns(true)
      Rails.application.config.action_mailer.stubs(:default_url_options).returns({ host: 'example.com', protocol: 'https' })

      service = RequestProviderInfo.new(application: @application, actor: @actor)

      assert_raises(ArgumentError) { service.send(:secure_url_for, 'some-token') }
    end

    test 'secure_url_for raises when protocol is not https in production' do
      Rails.env.stubs(:production?).returns(true)
      Rails.application.config.action_mailer.stubs(:default_url_options).returns({ host: 'mat.maryland.gov', protocol: 'http' })

      service = RequestProviderInfo.new(application: @application, actor: @actor)

      assert_raises(ArgumentError) { service.send(:secure_url_for, 'some-token') }
    end

    test 'address-only constituent receives a letter request with no digital contact snapshot' do
      user = build_address_only_constituent
      application = create(:application, user: user)
      ApplicationNotificationsMailer.unstub(:provider_info_requested)
      SmsService.expects(:send_message).never

      result = assert_difference('PrintQueueItem.count', 1) do
        RequestProviderInfo.new(application: application, actor: @actor).call
      end

      assert_predicate result, :success?
      form = result.data.fetch(:secure_request_forms).first
      assert_predicate form, :recipient_channel_letter?
      assert_nil form.recipient_email
      assert_nil form.recipient_phone
      print_item = PrintQueueItem.last
      assert_equal user.id, print_item.constituent_id
    end

    test 'no-route resolution creates no form notification audit event or transport call' do
      user = build_address_only_constituent
      user.update_columns(physical_address_1: nil, city: nil, state: nil, zip_code: nil)
      application = create(:application, user: user)
      ApplicationNotificationsMailer.expects(:provider_info_requested).never
      SmsService.expects(:send_message).never

      result = assert_no_difference(['SecureRequestForm.count', 'Notification.count', 'Event.count',
                                     'DuplicateReviewCase.count']) do
        RequestProviderInfo.new(application: application, actor: @actor).call
      end

      assert_not result.success?
      assert_equal I18n.t('applications.provider_info.messages.no_contact_path', locale: @actor.effective_locale),
                   result.message
    end

    test 'forged sms override for a voice phone fails without creating anything' do
      @application.user.update!(phone_type: 'voice')
      SmsService.expects(:send_message).never

      result = assert_no_difference(['SecureRequestForm.count', 'Notification.count']) do
        RequestProviderInfo.new(
          application: @application,
          actor: @actor,
          channel_overrides: { @application.user_id => 'sms' }
        ).call
      end

      assert_not result.success?
      assert_equal I18n.t('applications.provider_info.messages.invalid_channel_override', locale: @actor.effective_locale),
                   result.message
    end

    test 'unknown forged channel value fails without creating anything' do
      result = assert_no_difference(['SecureRequestForm.count', 'Notification.count']) do
        RequestProviderInfo.new(
          application: @application,
          actor: @actor,
          channel_overrides: { @application.user_id => 'carrier_pigeon' }
        ).call
      end

      assert_not result.success?
      assert_equal I18n.t('applications.provider_info.messages.invalid_channel_override', locale: @actor.effective_locale),
                   result.message
    end

    test 'a suspended recipient fails closed without issuing a request' do
      @application.user.update!(status: :suspended)

      result = assert_no_difference('SecureRequestForm.count') do
        RequestProviderInfo.new(application: @application, actor: @actor).call
      end

      assert_not result.success?
      assert_equal I18n.t('applications.provider_info.messages.recipient_no_longer_eligible',
                          locale: @actor.effective_locale),
                   result.message
    end

    test 'resend to a merged recipient fails closed and never redirects to the survivor' do
      original = RequestProviderInfo.new(application: @application, actor: @actor).call
                                    .data.fetch(:secure_request_forms).first
      survivor = create(:constituent)
      @application.user.update_columns(merged_into_user_id: survivor.id)

      result = assert_no_difference('SecureRequestForm.count') do
        travel_to original.sent_at + 2.hours do
          RequestProviderInfo.new(application: @application, actor: @actor, resend_of: original).call
        end
      end

      assert_not result.success?
      assert_equal I18n.t('applications.provider_info.messages.recipient_no_longer_eligible',
                          locale: @actor.effective_locale),
                   result.message
      assert_empty SecureRequestForm.where(recipient: survivor)
      assert_predicate original.reload, :status_sent?
      assert_not original.revoked?
    end

    test 'resend fails closed when the historical email channel is no longer deliverable' do
      original = RequestProviderInfo.new(application: @application, actor: @actor).call
                                    .data.fetch(:secure_request_forms).first
      @application.user.update_column(:email, nil)

      result = assert_no_difference(['SecureRequestForm.count', 'Notification.count']) do
        travel_to original.sent_at + 2.hours do
          RequestProviderInfo.new(application: @application, actor: @actor, resend_of: original).call
        end
      end

      assert_not result.success?
      assert_equal I18n.t('applications.provider_info.messages.invalid_channel_override',
                          locale: @actor.effective_locale),
                   result.message
      assert_predicate original.reload, :status_sent?
      assert_not original.revoked?
    end

    test 'resend keeps the historical channel but snapshots current contact' do
      original = RequestProviderInfo.new(application: @application, actor: @actor).call
                                    .data.fetch(:secure_request_forms).first
      new_email = "moved.#{SecureRandom.hex(3)}@example.com"
      @application.user.update!(email: new_email)

      result = nil
      travel_to original.sent_at + 2.hours do
        result = RequestProviderInfo.new(application: @application, actor: @actor, resend_of: original).call
      end

      assert_predicate result, :success?
      replacement = result.data.fetch(:secure_request_forms).first
      assert_predicate replacement, :recipient_channel_email?
      assert_equal new_email, replacement.recipient_email
      assert_predicate original.reload, :revoked?
    end

    test 'sms resend fails closed when the phone is no longer text capable' do
      @application.user.update!(phone_type: 'text')
      SmsService.stubs(:send_message).returns(true)
      original = RequestProviderInfo.new(
        application: @application,
        actor: @actor,
        channel_overrides: { @application.user_id => 'sms' }
      ).call.data.fetch(:secure_request_forms).first
      assert_predicate original, :recipient_channel_sms?

      @application.user.update!(phone_type: 'voice')
      SmsService.expects(:send_message).never

      result = assert_no_difference('SecureRequestForm.count') do
        travel_to original.sent_at + 2.hours do
          RequestProviderInfo.new(application: @application, actor: @actor, resend_of: original).call
        end
      end

      assert_not result.success?
      assert_predicate original.reload, :status_sent?
      assert_not original.revoked?
    end

    test 'letter resend fails closed when the address is no longer complete' do
      @application.user.update!(communication_preference: 'letter')
      ApplicationNotificationsMailer.unstub(:provider_info_requested)
      original = RequestProviderInfo.new(application: @application, actor: @actor).call
                                    .data.fetch(:secure_request_forms).first
      assert_predicate original, :recipient_channel_letter?

      @application.user.update_columns(physical_address_1: nil, city: nil, state: nil, zip_code: nil)

      result = assert_no_difference(['SecureRequestForm.count', 'PrintQueueItem.count']) do
        travel_to original.sent_at + 2.hours do
          RequestProviderInfo.new(application: @application, actor: @actor, resend_of: original).call
        end
      end

      assert_not result.success?
      assert_predicate original.reload, :status_sent?
      assert_not original.revoked?
    end

    # Defaults reject owner-ineligible routes as :no_contact_path before form creation.
    # Explicit overrides and resends reach delivery_participants_eligible? under lock.
    # They return :recipient_no_longer_eligible.
    test 'dependent email request fails closed when the guardian contact owner is suspended' do
      guardian, dependent, application = build_dependent_routed_through_guardian
      guardian.update!(status: :suspended)

      result = assert_no_difference('SecureRequestForm.count') do
        RequestProviderInfo.new(application: application, actor: @actor,
                                recipient_ids: [dependent.id]).call
      end

      assert_not result.success?
      assert_equal I18n.t('applications.provider_info.messages.no_contact_path',
                          locale: @actor.effective_locale),
                   result.message
    end

    test 'dependent email request fails closed when the guardian contact owner is inactive' do
      guardian, dependent, application = build_dependent_routed_through_guardian
      guardian.update!(status: :inactive)

      result = assert_no_difference('SecureRequestForm.count') do
        RequestProviderInfo.new(application: application, actor: @actor,
                                recipient_ids: [dependent.id]).call
      end

      assert_not result.success?
      assert_equal I18n.t('applications.provider_info.messages.no_contact_path',
                          locale: @actor.effective_locale),
                   result.message
    end

    test 'dependent email request fails closed when the guardian contact owner has been merged' do
      guardian, dependent, application = build_dependent_routed_through_guardian
      survivor = create(:constituent)
      guardian.update_columns(merged_into_user_id: survivor.id)

      result = assert_no_difference('SecureRequestForm.count') do
        RequestProviderInfo.new(application: application, actor: @actor,
                                recipient_ids: [dependent.id]).call
      end

      assert_not result.success?
      assert_equal I18n.t('applications.provider_info.messages.no_contact_path',
                          locale: @actor.effective_locale),
                   result.message
      assert_empty SecureRequestForm.where(recipient: survivor)
    end

    test 'dependent sms request fails closed when the guardian contact owner is suspended' do
      guardian, dependent, application = build_dependent_routed_through_guardian(
        phone: '410-555-0180', phone_type: 'text'
      )
      guardian.update!(status: :suspended)
      SmsService.expects(:send_message).never

      result = assert_no_difference('SecureRequestForm.count') do
        RequestProviderInfo.new(application: application, actor: @actor,
                                recipient_ids: [dependent.id],
                                channel_overrides: { dependent.id => 'sms' }).call
      end

      assert_not result.success?
      assert_equal I18n.t('applications.provider_info.messages.recipient_no_longer_eligible',
                          locale: @actor.effective_locale),
                   result.message
    end

    test 'dependent letter request fails closed when the guardian address owner is suspended' do
      guardian, dependent, application = build_dependent_routed_through_guardian(
        communication_preference: 'letter'
      )
      guardian.update!(status: :suspended)
      ApplicationNotificationsMailer.unstub(:provider_info_requested)

      result = assert_no_difference(['SecureRequestForm.count', 'PrintQueueItem.count']) do
        RequestProviderInfo.new(application: application, actor: @actor,
                                recipient_ids: [dependent.id]).call
      end

      assert_not result.success?
      assert_equal I18n.t('applications.provider_info.messages.no_contact_path',
                          locale: @actor.effective_locale),
                   result.message
    end

    test 'resend fails closed when the guardian contact owner was suspended after issuance' do
      _guardian, dependent, application = build_dependent_routed_through_guardian
      original = RequestProviderInfo.new(application: application, actor: @actor,
                                         recipient_ids: [dependent.id]).call
                                    .data.fetch(:secure_request_forms).first
      assert_predicate original, :recipient_channel_email?

      application.managing_guardian.update!(status: :suspended)

      result = assert_no_difference('SecureRequestForm.count') do
        travel_to original.sent_at + 2.hours do
          RequestProviderInfo.new(application: application, actor: @actor, resend_of: original).call
        end
      end

      assert_not result.success?
      assert_equal I18n.t('applications.provider_info.messages.recipient_no_longer_eligible',
                          locale: @actor.effective_locale),
                   result.message
      assert_predicate original.reload, :status_sent?
      assert_not original.revoked?
    end

    test 'persists resolver delivery ownership on the form and notification' do
      guardian, dependent, application = build_dependent_routed_through_guardian

      result = RequestProviderInfo.new(application: application, actor: @actor,
                                       recipient_ids: [dependent.id]).call

      assert_predicate result, :success?
      form = result.data.fetch(:secure_request_forms).first
      assert_equal guardian, form.delivery_owner
      assert_equal 'managing_guardian', form.delivery_source

      # AuditLogBuilder includes this notification action without consulting the audited flag.
      # The notification owns the durable audit of delivery.
      notification = Notification.find_by!(notifiable: application, action: 'provider_info_requested',
                                           recipient: dependent)
      assert_equal guardian.id, notification.metadata['delivery_owner_id']
      assert_equal 'managing_guardian', notification.metadata['delivery_source']
    end

    test 'explicit SMS with a dependent-owned email records the phone field provenance' do
      # The email comes from dependent_email, but SMS uses the constituent phone field.
      guardian = create(:constituent, email: "guardian.smx.#{SecureRandom.hex(4)}@example.com")
      dependent = create(
        :constituent,
        email: "dependent.smx.#{SecureRandom.hex(4)}@system.matvulcan.local",
        dependent_email: "dependent-owned.#{SecureRandom.hex(4)}@example.com",
        phone: "555-#{rand(200..899)}-#{rand(1000..9999)}",
        phone_type: 'text'
      )
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent,
                                     relationship_type: 'Parent')
      application = create(:application, user: dependent, managing_guardian: guardian)

      SmsService.stubs(:send_message).returns(true)
      result = RequestProviderInfo.new(application: application, actor: @actor,
                                       recipient_ids: [dependent.id],
                                       channel_overrides: { dependent.id => 'sms' }).call

      assert_predicate result, :success?
      form = result.data.fetch(:secure_request_forms).first
      assert_predicate form, :recipient_channel_sms?
      assert_equal dependent, form.delivery_owner
      assert_equal 'constituent', form.delivery_source

      notification = Notification.find_by!(notifiable: application, action: 'provider_info_requested',
                                           recipient: dependent)
      assert_equal dependent.id, notification.metadata['delivery_owner_id']
      assert_equal 'constituent', notification.metadata['delivery_source']
    end

    test 'self-delivered constituent request records the constituent as delivery owner' do
      result = RequestProviderInfo.new(application: @application, actor: @actor).call

      assert_predicate result, :success?
      form = result.data.fetch(:secure_request_forms).first
      assert_equal @application.user, form.delivery_owner
      assert_equal 'constituent', form.delivery_source
    end

    test 'letter request records the guardian household as delivery owner and source' do
      guardian, dependent, application = build_dependent_routed_through_guardian(
        communication_preference: 'letter'
      )

      result = RequestProviderInfo.new(application: application, actor: @actor,
                                       recipient_ids: [dependent.id]).call

      assert_predicate result, :success?
      form = result.data.fetch(:secure_request_forms).first
      assert_predicate form, :recipient_channel_letter?
      assert_equal guardian, form.delivery_owner
      assert_equal 'managing_guardian', form.delivery_source
    end

    test 'dependent with own email falls back from an owner-ineligible letter route' do
      # Only the letter route belongs to the suspended guardian.
      guardian = create(:constituent, physical_address_1: '9 Guardian Way')
      dependent_email = "dependent.mixed.#{SecureRandom.hex(4)}@example.com"
      dependent = create(:constituent, email: dependent_email, dependent_email: dependent_email,
                                       communication_preference: 'letter')
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent,
                                     relationship_type: 'Parent')
      application = create(:application, user: dependent, managing_guardian: guardian)
      guardian.update!(status: :suspended)
      @mailer_delivery.expects(:deliver_now).returns(true)

      result = RequestProviderInfo.new(application: application, actor: @actor,
                                       recipient_ids: [dependent.id]).call

      assert_predicate result, :success?
      form = result.data.fetch(:secure_request_forms).first
      assert_predicate form, :recipient_channel_email?
      assert_equal dependent, form.delivery_owner
      assert_equal 'dependent_contact', form.delivery_source
    end
  end
end
