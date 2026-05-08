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

    test 'sms request keeps NotificationService channel compatible while recording requested channel' do
      @application.user.update!(phone_type: 'text')
      SmsService.stubs(:send_message).returns(true)

      result = RequestProviderInfo.new(application: @application, actor: @actor).call

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

      # Issue to guardian only, putting guardian on cooldown
      first_result = RequestProviderInfo.new(
        application: @application,
        actor: @actor,
        recipient_ids: [guardian.id]
      ).call
      assert_predicate first_result, :success?

      # Now attempt multi-recipient issuance (applicant + guardian).
      # Guardian is still in cooldown, so the whole batch should roll back.
      multi_result = assert_no_difference(['SecureRequestForm.count', 'Notification.count']) do
        RequestProviderInfo.new(
          application: @application,
          actor: @actor,
          recipient_ids: [@application.user_id, guardian.id]
        ).call
      end

      assert_not multi_result.success?
      assert_match(/minute/, multi_result.message)

      # The applicant's individual request still works since their cooldown is clear
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

    # -----------------------------------------------------------------------
    # Guardian repair: single guardian auto-sets managing_guardian_id
    # -----------------------------------------------------------------------

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

    # -----------------------------------------------------------------------
    # Multi-recipient: shared request_batch_id
    # -----------------------------------------------------------------------

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

    # -----------------------------------------------------------------------
    # Recipient-scoped cooldown independence
    # -----------------------------------------------------------------------

    test 'resend cooldown for recipient A does not block recipient B from receiving their own resend' do
      guardian = create(:constituent)
      create(:guardian_relationship, dependent_user: @application.user, guardian_user: guardian)

      # Issue to the applicant only, putting the applicant on cooldown
      applicant_result = RequestProviderInfo.new(
        application: @application,
        actor: @actor,
        recipient_ids: [@application.user_id]
      ).call
      assert_predicate applicant_result, :success?

      # Guardian has never been issued a link; their issuance must not be blocked
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

    # -----------------------------------------------------------------------
    # Token not in Notification metadata
    # -----------------------------------------------------------------------

    test 'raw bearer token does not appear in Notification metadata after issuance' do
      # Use a recognisable sentinel token so we can assert its absence clearly.
      # Stub generate_public_token (class method) to return the sentinel value;
      # this is called exactly once for a single-recipient issuance.
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

    # -----------------------------------------------------------------------
    # No duplicate custom audit event for issuance
    # -----------------------------------------------------------------------

    test 'issuance does not create a custom secure_link_sent audit event beyond the NotificationService record' do
      # The issuer must rely solely on the NotificationService audit event for
      # provider_info_requested. A separate custom secure_link_sent Event would
      # mean two audit records for the same logical issuance event.
      assert_no_difference -> { Event.where(action: 'secure_link_sent').count } do
        result = RequestProviderInfo.new(application: @application, actor: @actor).call
        assert_predicate result, :success?
      end
    end

    # -----------------------------------------------------------------------
    # secure_url_for rejects unsafe production config
    # -----------------------------------------------------------------------

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
  end
end
