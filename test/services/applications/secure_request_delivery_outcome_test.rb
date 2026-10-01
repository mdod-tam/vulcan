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
      delivery_failure = result.data[:delivery_failures].first
      assert_equal 'EmailDelivery::ConfigurationError', delivery_failure[:error_class]
      assert_equal application.id, delivery_failure[:application_id]
      assert_equal [form.id], delivery_failure[:secure_request_form_ids]
      assert_equal [form.recipient_id], delivery_failure[:recipient_ids]
      assert_equal ['email'], delivery_failure[:recipient_channels]
      assert_equal 'id', delivery_failure[:proof_type] if service_class == Applications::RequestProofResubmission
      assert_predicate form, :revoked?
      assert_equal 'delivery_configuration_error', event.metadata['reason']
      assert_equal 'error', notification.delivery_status
      assert_match(/configuration_error/, notification.metadata['delivery_route_reason'])
    end
  end

  [Applications::RequestCertificationUpload, Vendors::RequestW9Resubmission].each do |service_class|
    test "#{service_class} rolls back its request when required tracking cannot be created" do
      service, owner, = single_request_service(service_class)
      NotificationService.stubs(:create_and_deliver!).returns(nil)

      result = assert_no_difference ['Notification.count', 'MedicalProviderSecureRequestForm.count', 'VendorSecureRequestForm.count',
                                     'ApplicationStatusChange.count', 'Event.count'] do
        service.call
      end

      assert_predicate result, :failure?
      assert_predicate owner.reload, :medical_certification_status_not_requested? if service_class == Applications::RequestCertificationUpload
    end

    test "#{service_class} restores and revokes on late configuration refusal" do
      service, owner, form_key, action = single_request_service(service_class)
      EmailDelivery::Policy.stubs(:verify_delivery).returns(EmailDelivery::Decision.allowed)
                           .then.returns(EmailDelivery::Decision.configuration_error(:missing_control))

      result = service.call

      form = result.data.fetch(form_key).reload
      notification = Notification.find_by!(notifiable: owner, action: action)
      assert result.data[:configuration_error]
      delivery_failure = result.data.fetch(:delivery_failure)
      owner_key = service_class == Applications::RequestCertificationUpload ? :application_id : :vendor_id
      assert_equal owner.id, delivery_failure.fetch(owner_key)
      assert_equal form.id, delivery_failure.fetch(:"#{form_key}_id")
      assert_equal form.request_batch_id, delivery_failure.fetch(:request_batch_id)
      assert_equal [form.id], delivery_failure.fetch(:secure_request_form_ids)
      assert_empty delivery_failure.fetch(:recipient_ids)
      assert_equal ['email'], delivery_failure.fetch(:recipient_channels)
      assert_equal 'missing_control', delivery_failure.fetch(:reason)
      assert_predicate form, :revoked?
      assert_equal 'delivery_configuration_error', Event.where(action: form.revocation_audit_action).order(:id).last.metadata['reason']
      assert_equal 'error', notification.delivery_status
      assert_equal 'missing_control', notification.metadata.dig('delivery_error', 'reason')
      next unless service_class == Applications::RequestCertificationUpload

      assert_predicate owner.reload, :medical_certification_status_not_requested?
      assert_equal 0, owner.medical_certification_request_count
      assert_nil owner.medical_certification_requested_at
      assert_equal 'delivery_not_sent', owner.status_changes.order(:id).last.metadata['reason']
      assert Event.exists?(action: 'medical_certification_request_not_sent', auditable: owner)
    end

    test "#{service_class} revokes despite failure tracking being unavailable" do
      service, owner, form_key, action = single_request_service(service_class)
      mail = mock('failed secure request email')
      mail.stubs(:deliver_now).raises(StandardError, 'transport failed')
      mailer = mock('secure request mailer')
      if service_class == Applications::RequestCertificationUpload
        MedicalProviderMailer.stubs(:with).returns(mailer)
        mailer.stubs(:request_certification).returns(mail)
      else
        VendorNotificationsMailer.stubs(:with).returns(mailer)
        mailer.stubs(:w9_upload_requested).returns(mail)
      end
      Notification.any_instance.stubs(:mark_delivery_failed!).raises(StandardError, 'tracking write failed')

      result = service.call

      assert result.data[:delivery_error]
      assert_predicate result.data.fetch(form_key).reload, :revoked?
      assert Notification.exists?(notifiable: owner, action: action)
    end
  end

  private

  def single_request_service(service_class)
    if service_class == Applications::RequestCertificationUpload
      application = create(:application, :in_progress, medical_provider_name: 'Dr. Provider', medical_provider_email: 'provider@example.test')
      [service_class.new(application: application, actor: @actor, deliver_email: true), application,
       :medical_provider_secure_request_form, 'cert_upload_requested']
    else
      vendor = create(:vendor, w9_status: :not_submitted)
      [service_class.new(vendor: vendor, actor: @actor), vendor, :vendor_secure_request_form, 'w9_resubmission_requested']
    end
  end
end
