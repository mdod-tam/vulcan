# frozen_string_literal: true

require 'test_helper'

class EmailDeliveryOutcomeTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    ensure_system_audit_actor!
    @admin = create(:admin)
    @vendor = create(:vendor)
    load_seeded_email_templates('vendor_notifications_w9_approved', 'user_mailer_password_reset')
    clear_enqueued_jobs
    ActionMailer::Base.deliveries.clear
    EmailDelivery::Current.reset
  end

  teardown { EmailDelivery::Current.reset }

  test 'missing category configuration stays an error through the real notification caller' do
    FeatureFlag.find_by!(name: EmailDelivery.category_control('vendor')).destroy!

    notification = notify_vendor

    assert_configuration_error(notification)
    assert_empty enqueued_jobs
    assert_empty ActionMailer::Base.deliveries
    assert Event.exists?(action: EmailDelivery::Outcome::CONFIGURATION_ERROR)
    assert_not Event.exists?(action: EmailDelivery::Outcome::SUPPRESSED)
    assert_not Event.exists?(auditable: notification, action: 'notification_w9_approved_sent')
  end

  test 'a configuration read failure is not intentional suppression' do
    EmailDelivery::Policy.stubs(:global_control!).raises(ActiveRecord::ConnectionNotEstablished, 'read unavailable')

    assert_configuration_error(notify_vendor)

    assert_empty enqueued_jobs
    assert_empty ActionMailer::Base.deliveries
  end

  test 'configuration failure returns its own enqueue result and does not leak to the next send' do
    EmailDelivery::Policy.stubs(:verify_delivery).returns(EmailDelivery::Decision.configuration_error(:unavailable))

    assert_equal :configuration_error, EmailDelivery.deliver_later(vendor_mail)

    EmailDelivery::Policy.unstub(:verify_delivery)
    assert_equal :queued, EmailDelivery.deliver_later(vendor_mail)
    assert_nil EmailDelivery::Current.denial_reason
    assert_equal 1, enqueued_jobs.size
  end

  test 'an explicit off setting remains suppression and is not audited as sent' do
    EmailDelivery::ControlWriter.set(name: EmailDelivery::GLOBAL_CONTROL, enabled: false, actor: @admin,
                                     operation_id: SecureRandom.uuid)

    notification = notify_vendor.reload

    assert_equal 'suppressed', notification.delivery_status
    assert_equal 'global_disabled', notification.metadata.dig('delivery_suppressed', 'reason')
    assert_equal 'none', notification.metadata['actual_delivery_channel']
    assert_not Event.exists?(auditable: notification, action: 'notification_w9_approved_sent')
    assert_empty enqueued_jobs
  end

  test 'a synchronous configuration refusal is an operational exception' do
    EmailDelivery::Policy.stubs(:verify_delivery).returns(EmailDelivery::Decision.configuration_error(:unavailable))

    assert_raises(EmailDelivery::ConfigurationError) { EmailDelivery.deliver_now!(vendor_mail) }

    assert_empty ActionMailer::Base.deliveries
  end

  test 'worker-time configuration failure persists an error and survives a later routing write' do
    notification = notify_vendor
    stale = Notification.find(notification.id)
    EmailDelivery::Policy.stubs(:verify_delivery).returns(EmailDelivery::Decision.configuration_error(:unavailable))

    perform_enqueued_jobs
    NotificationService.new.send(:persist_delivery_routing_metadata, stale,
                                 actual_delivery_channel: 'email', delivery_route_reason: 'requested_channel')

    assert_configuration_error(notification)
    assert_empty ActionMailer::Base.deliveries
  end

  test 'an audit error on a stale caller preserves the worker refusal' do
    notification = notify_vendor
    stale = Notification.find(notification.id)
    notification.mark_delivery_suppressed!('global_disabled')

    NotificationService.new.send(:handle_audit_trail_error, stale, StandardError.new('audit unavailable'))

    assert_equal 'global_disabled', notification.reload.metadata.dig('delivery_suppressed', 'reason')
    assert_equal 'none', notification.metadata['actual_delivery_channel']
    assert_equal 'audit unavailable', notification.metadata.dig('audit_error', 'message')
  end

  test 'a later handler error cannot overwrite a recorded configuration refusal' do
    notification = notify_vendor
    stale = Notification.find(notification.id)
    notification.mark_delivery_not_sent!(EmailDelivery::Decision.configuration_error(:unavailable))

    NotificationService.new.send(:handle_delivery_error, stale, StandardError.new('caller failure'), :email)

    assert_configuration_error(notification)
    assert_equal 'unavailable', notification.metadata.dig('delivery_error', 'reason')
  end

  test 'nested job contexts restore the outer decision and identity' do
    outer = EmailDelivery::Decision.suppressed(:global_disabled)
    EmailDelivery::Current.set(context: { 'request_id' => 'outer' }, queued: true, denial_decision: outer) do
      EmailDelivery::Current.set(context: { 'request_id' => 'inner' }, queued: true, denial_decision: nil) do
        assert_nil EmailDelivery::Current.denial_decision
        EmailDelivery::Current.denial_decision = EmailDelivery::Decision.configuration_error(:unavailable)
      end

      assert_same outer, EmailDelivery::Current.denial_decision
      assert_equal 'outer', EmailDelivery::Current.context['request_id']
    end
    assert_nil EmailDelivery::Current.context
    assert_nil EmailDelivery::Current.denial_decision
  end

  test 'an admin test send reports unavailable settings rather than an off switch' do
    template = EmailTemplate.find_by!(name: 'user_mailer_password_reset', format: :text, locale: 'en')
    FeatureFlag.find_by!(name: EmailDelivery.category_control('account_security')).destroy!
    sign_in_for_integration_test(@admin)

    post send_test_admin_email_template_path(template), headers: default_headers,
                                                        params: { admin_test_email_form: { email: @admin.email, template_id: template.id } }

    assert_redirected_to admin_email_template_path(template)
    assert_includes flash[:alert], 'settings'
    assert_not_includes flash[:alert], 'turned off'
    assert_empty enqueued_jobs
  end

  private

  def notify_vendor
    NotificationService.create_and_deliver!(type: :w9_approved, recipient: @vendor, actor: @admin,
                                            notifiable: @vendor, channel: :email, audit: true)
  end

  def vendor_mail
    VendorNotificationsMailer.with(vendor: @vendor).w9_approved
  end

  def assert_configuration_error(notification)
    assert notification
    notification.reload
    assert_equal 'error', notification.delivery_status
    assert_equal 'none', notification.metadata['actual_delivery_channel']
    assert_equal 'email_configuration_error', notification.metadata['delivery_route_reason']
    assert_match(/settings/i, notification.email_error_message)
    assert_not notification.metadata.key?('delivery_suppressed')
  end
end
