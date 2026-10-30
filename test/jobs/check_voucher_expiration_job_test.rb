# frozen_string_literal: true

require 'test_helper'

# Runs the real processor and mail jobs. The expiration queries use the database clock,
# so issue dates are set relative to the current time rather than frozen Ruby time.
class CheckVoucherExpirationJobTest < ActiveJob::TestCase
  # Annual validity keeps warning fixtures in range across month-end and leap-day clipping.
  VALIDITY_MONTHS = 12

  setup do
    actor = ensure_system_audit_actor!
    Policy.find_or_initialize_by(key: 'voucher_validity_period_months').update!(value: VALIDITY_MONTHS, updated_by: actor)
    load_seeded_email_templates('voucher_notifications_voucher_expiring_soon', 'voucher_notifications_voucher_expired')
    ActionMailer::Base.deliveries.clear
  end

  test 'warns a voucher inside the expiring-soon window once across repeated runs' do
    voucher = create_warning_voucher

    2.times { perform_enqueued_jobs { CheckVoucherExpirationJob.perform_now } }

    assert voucher.reload.voucher_active?
    assert_equal 1, voucher.events.where(action: Vouchers::ExpirationProcessorService::WARNING_ACTION).count
    assert_equal [[voucher_email(voucher)]], ActionMailer::Base.deliveries.map(&:to)
  end

  test 'expires a past-due voucher and sends exactly one expired notice' do
    voucher = create_voucher(expires_in: -1.day)

    2.times { perform_enqueued_jobs { CheckVoucherExpirationJob.perform_now } }

    assert voucher.reload.voucher_expired?
    assert_equal 1, voucher.events.where(action: 'expired').count
    assert_equal 1, ActionMailer::Base.deliveries.size
    assert_equal [voucher_email(voucher)], ActionMailer::Base.deliveries.first.to
    notification = Notification.find_by!(notifiable: voucher, action: 'voucher_expired')
    assert_equal PublicAuditActor.system_audit_actor.id, notification.actor_id
    assert_equal notification.id, notification.metadata.dig('expiration_delivery_context', 'notification_id')
  end

  test 'expiration audit failure rolls back status and notice intent before anything is queued' do
    voucher = create_voucher(expires_in: -1.day)
    AuditEventService.stubs(:log).raises(ActiveRecord::RecordInvalid.new(Event.new))

    assert_no_enqueued_jobs only: EmailDelivery::MailDeliveryJob do
      assert_no_difference -> { Notification.where(notifiable: voucher, action: 'voucher_expired').count } do
        assert_predicate Vouchers::ExpirationProcessorService.new.call, :failure?
      end
    end
    assert voucher.reload.voucher_active?
    assert_not voucher.events.exists?(action: 'expired')
  end

  test 'expiration notification creation failure rolls back its status and audit' do
    voucher = create_voucher(expires_in: -1.day)
    Notification.stubs(:create!).raises(ActiveRecord::RecordInvalid.new(Notification.new))

    assert_no_enqueued_jobs only: EmailDelivery::MailDeliveryJob do
      assert_predicate Vouchers::ExpirationProcessorService.new.call, :failure?
    end

    assert voucher.reload.voucher_active?
    assert_not voucher.events.exists?(action: 'expired')
    assert_not Notification.exists?(notifiable: voucher, action: 'voucher_expired')
  end

  test 'a failed expired-notice enqueue recovers from its intent after the voucher left the active scope' do
    voucher = create_voucher(expires_in: -1.day)
    adapter = EmailDelivery::MailDeliveryJob.queue_adapter
    adapter.stubs(:enqueue).raises(ActiveJob::EnqueueError, 'queue unavailable')

    CheckVoucherExpirationJob.perform_now

    assert voucher.reload.voucher_expired?
    notification = Notification.find_by!(notifiable: voucher, action: 'voucher_expired')
    context = notification.metadata.fetch('expiration_delivery_context')
    assert_equal 'error', notification.delivery_status
    assert_equal 'email_enqueue_failed', notification.metadata['delivery_route_reason']
    assert_empty ActionMailer::Base.deliveries
    adapter.unstub(:enqueue)

    2.times { perform_enqueued_jobs { CheckVoucherExpirationJob.perform_now } }

    assert_equal 1, voucher.events.where(action: 'expired').count
    assert_equal 1, Notification.where(notifiable: voucher, action: 'voucher_expired').count
    assert_equal context, notification.reload.metadata['expiration_delivery_context']
    assert_equal [[voucher_email(voucher)]], ActionMailer::Base.deliveries.map(&:to)
  end

  test 'a saved notice intent survives a failure before dispatch and keeps its original control capture' do
    voucher = create_voucher(expires_in: -1.day)
    processor = Vouchers::ExpirationProcessorService.new
    processor.stubs(:deliver_pending_expiration_notices).returns(nil).then.raises(StandardError, 'worker stopped before dispatch')

    assert_predicate processor.call, :failure?
    assert voucher.reload.voucher_expired?
    notification = Notification.find_by!(notifiable: voucher, action: 'voucher_expired')
    assert_nil notification.delivery_status
    context = notification.metadata.fetch('expiration_delivery_context')

    perform_enqueued_jobs { CheckVoucherExpirationJob.perform_now }

    assert_equal context, notification.reload.metadata['expiration_delivery_context']
    assert_equal 1, ActionMailer::Base.deliveries.size
  end

  test 'a voucher between the warning and expiry windows receives no notice' do
    voucher = create_voucher(expires_in: 4.days)

    perform_enqueued_jobs { CheckVoucherExpirationJob.perform_now }

    assert voucher.reload.voucher_active?
    assert_empty ActionMailer::Base.deliveries
  end

  test 'a disabled expired template still expires the voucher without mail' do
    EmailTemplate.where(name: 'voucher_notifications_voucher_expired').update_all(enabled: false)
    voucher = create_voucher(expires_in: -1.day)

    perform_enqueued_jobs { CheckVoucherExpirationJob.perform_now }

    assert voucher.reload.voucher_expired?
    assert_empty ActionMailer::Base.deliveries
    notification = Notification.find_by!(notifiable: voucher, action: 'voucher_expired')
    assert notification.suppressed_delivery_status?
    context = notification.metadata.fetch('expiration_delivery_context')
    EmailTemplate.where(name: 'voucher_notifications_voucher_expired').update_all(enabled: true)

    perform_enqueued_jobs { CheckVoucherExpirationJob.perform_now }

    assert_equal context, notification.reload.metadata['expiration_delivery_context']
    assert_empty ActionMailer::Base.deliveries
  end

  test 'an intentionally suppressed warning is recorded truthfully and never replayed' do
    voucher = create_warning_voucher
    admin = create(:admin)
    EmailDelivery::ControlWriter.set(name: EmailDelivery::ALL_CONTROL, enabled: false, actor: admin, operation_id: SecureRandom.uuid)
    perform_enqueued_jobs { CheckVoucherExpirationJob.perform_now }

    event = voucher.events.find_by!(action: Vouchers::ExpirationProcessorService::WARNING_ACTION)
    assert_equal 'suppressed', event.metadata['delivery_outcome']
    assert_not voucher.events.exists?(action: 'expiration_warning_sent')
    assert Event.with_metadata(:request_id, event.metadata['delivery_request_id']).exists?(action: EmailDelivery::Outcome::SUPPRESSED)
    EmailDelivery::ControlWriter.set(name: EmailDelivery::ALL_CONTROL, enabled: true, actor: admin, operation_id: SecureRandom.uuid)
    perform_enqueued_jobs { CheckVoucherExpirationJob.perform_now }
    assert_empty ActionMailer::Base.deliveries
    assert_equal 1, voucher.events.where(action: Vouchers::ExpirationProcessorService::WARNING_ACTION).count
  end

  test 'legacy sent-warning history still prevents duplicate warnings' do
    voucher = create_warning_voucher
    voucher.events.create!(user: ensure_system_audit_actor!, action: 'expiration_warning_sent')
    perform_enqueued_jobs { CheckVoucherExpirationJob.perform_now }
    assert_empty ActionMailer::Base.deliveries
    assert_not voucher.events.exists?(action: Vouchers::ExpirationProcessorService::WARNING_ACTION)
  end

  test 'a queue failure does not consume the voucher warning' do
    voucher = create_warning_voucher
    adapter = EmailDelivery::MailDeliveryJob.queue_adapter
    adapter.stubs(:enqueue).raises(ActiveJob::EnqueueError, 'queue unavailable')
    CheckVoucherExpirationJob.perform_now
    assert_not voucher.events.exists?(action: Vouchers::ExpirationProcessorService::WARNING_ACTION)

    adapter.unstub(:enqueue)
    perform_enqueued_jobs { CheckVoucherExpirationJob.perform_now }
    assert_equal 1, ActionMailer::Base.deliveries.size
  end

  private

  def create_warning_voucher
    voucher = create_voucher(expires_in: 7.days)
    candidates = Vouchers::ExpirationProcessorService.new.send(:vouchers_expiring_soon)
    assert candidates.exists?(id: voucher.id), 'Warning fixture must be inside the database warning window'
    voucher
  end

  def create_voucher(expires_in:)
    application = create(:application, :completed)
    Voucher.create!(
      application: application,
      initial_value: 500,
      remaining_value: 500,
      status: :active,
      issued_at: expires_in.from_now.utc - VALIDITY_MONTHS.months
    )
  end

  def voucher_email(voucher)
    voucher.application.user.email
  end
end
