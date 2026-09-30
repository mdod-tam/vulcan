# frozen_string_literal: true

require 'test_helper'

class SecureRequestDeliveryOutcomeTest < ActiveSupport::TestCase
  setup do
    @actor = create(:admin)
    ensure_system_audit_actor!
    Rails.error.stubs(:report)
  end

  [Applications::RequestProofResubmission, Applications::RequestProviderInfo].each do |service_class|
    test "#{service_class} revocation survives a subsequent notification write failure" do
      application = create(:application, :in_progress)
      delivery = mock('delivery')
      delivery.stubs(:deliver_now).raises(EmailDelivery::ConfigurationError.new(reason: 'missing_control'))
      ApplicationNotificationsMailer.stubs(:proof_requested).returns(delivery)
      ApplicationNotificationsMailer.stubs(:provider_info_requested).returns(delivery)
      Notification.any_instance.stubs(:mark_delivery_not_sent!).raises(StandardError, 'tracking write failed')
      args = { application: application, actor: @actor }
      args[:proof_type] = :id if service_class == Applications::RequestProofResubmission

      result = service_class.new(**args).call

      assert result.data[:configuration_error]
      assert_predicate result.data[:secure_request_forms].first.reload, :revoked?
    end

    test "#{service_class} continues other recipients and revokes even when reporting fails" do
      application = create(:application, :in_progress)
      guardian = create(:constituent)
      create(:guardian_relationship, guardian_user: guardian, dependent_user: application.user)
      application.update!(managing_guardian: guardian)
      delivery = Object.new
      attempts = 0
      delivery.define_singleton_method(:deliver_now) do
        attempts += 1
        raise EmailDelivery::ConfigurationError.new(reason: 'missing_control') if attempts == 1

        true
      end
      ApplicationNotificationsMailer.stubs(:proof_requested).returns(delivery)
      ApplicationNotificationsMailer.stubs(:provider_info_requested).returns(delivery)
      Rails.error.stubs(:report).raises(StandardError, 'reporter down')
      args = { application: application, actor: @actor, recipient_ids: [application.user_id, guardian.id] }
      args[:proof_type] = :id if service_class == Applications::RequestProofResubmission

      result = service_class.new(**args).call

      assert_equal 2, attempts
      assert result.data[:configuration_error]
      assert_equal 'missing_control', result.data[:reason]
      forms = result.data[:secure_request_forms].map(&:reload)
      assert_equal 1, forms.count(&:revoked?)
      assert_equal 1, forms.count(&:active?)
      failed_notification = Notification.find_by!(notifiable: application, recipient_id: forms.find(&:revoked?).recipient_id)
      assert_equal 'error', failed_notification.delivery_status
      assert_equal 'missing_control', failed_notification.metadata.dig('delivery_error', 'reason')
    end

    test "late configuration error result for #{service_class}" do
      application = create(:application, :in_progress)
      delivery = Object.new
      delivery.define_singleton_method(:deliver_now) do
        context = EmailDelivery::Current.context
        category = EmailDelivery::Catalog.mail_action(context['mail_action']).category
        FeatureFlag.where(name: EmailDelivery.category_control(category)).delete_all
        EmailDelivery.verify!(context['mail_action'], context: context, channel: :email)
      end
      ApplicationNotificationsMailer.stubs(:proof_requested).returns(delivery)
      ApplicationNotificationsMailer.stubs(:provider_info_requested).returns(delivery)
      args = { application: application, actor: @actor }
      args[:proof_type] = :id if service_class == Applications::RequestProofResubmission
      result = service_class.new(**args).call
      form = result.data.fetch(:secure_request_forms).first.reload
      event = Event.where(action: form.revocation_audit_action).order(:id).last
      notification = Notification.where(notifiable: application).order(:id).last
      assert_predicate result, :failure?
      assert result.data[:delivery_error]
      assert result.data[:configuration_error]
      assert_equal 'EmailDelivery::ConfigurationError', result.data[:delivery_failures].first[:error_class]
      assert_predicate form, :revoked?
      assert_equal 'delivery_configuration_error', event.metadata['reason']
      assert_equal 'error', notification.delivery_status
      assert_match(/configuration_error/, notification.metadata['delivery_route_reason'])
    end
  end
end
