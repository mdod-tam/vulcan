# frozen_string_literal: true

require 'test_helper'

class PruneContactVerificationsJobTest < ActiveSupport::TestCase
  setup do
    Current.reset
    ensure_system_audit_actor!
    @user = create(:constituent)
    Current.user = @user
    @record = Session.create!(user: @user, ip_address: '127.0.0.1', user_agent: 'Contact retention fixture',
                              reauthenticated_at: Time.current, reauthenticated_security_version: @user.security_version)
    @writer = Users::ContactChange.new(user: @user, actor: @user, session: @record, token: @record.session_token)
  end

  test 'reconciliation requeues the same proof envelope without extending its deadline' do
    change = create_change(states: { 'new_email' => 'queued' })
    deadline = change.expires_at
    context = change.delivery_contexts.fetch('new_email')
    ContactChangeDeliveryJob.expects(:perform_later).with(change.id, 'new_email').returns(stub(successfully_enqueued?: true))
    PruneContactVerificationsJob.perform_now
    assert_equal deadline, change.reload.expires_at
    assert_equal context, change.delivery_contexts.fetch('new_email')

    EmailDelivery.expects(:deliver_now!).with(anything, context: context).returns(Mail.new)
    ContactChangeDeliveryJob.perform_now(change.id, 'new_email')
    assert_equal 'submitted', change.reload.delivery_states.fetch('new_email')
    assert_equal deadline, change.expires_at
    assert_equal context, change.delivery_contexts.fetch('new_email')
  end

  test 'expired requests cannot requeue proof or send a delayed proof job' do
    change = create_change(expires_at: 1.hour.ago, states: { 'old_email' => 'error', 'new_email' => 'queued' })
    ContactChangeDeliveryJob.expects(:perform_later).never
    EmailDelivery.expects(:deliver_now!).never
    PruneContactVerificationsJob.perform_now
    ContactChangeDeliveryJob.perform_now(change.id, 'new_email')
    assert ContactChangeRequest.exists?(change.id)
    assert_equal 'queued', change.reload.delivery_states.fetch('new_email')
    assert_nil change.completed_at
  end

  test 'proof expiry does not abandon a completed contact security notice before retention ends' do
    change = create_change(completed: true, expires_at: 1.hour.ago, states: { 'old_completed' => 'queued' })
    context = change.delivery_contexts.fetch('old_completed')
    ContactChangeDeliveryJob.expects(:perform_later).with(change.id, 'old_completed').returns(stub(successfully_enqueued?: true))
    PruneContactVerificationsJob.perform_now
    assert ContactChangeRequest.exists?(change.id)
    assert_equal context, change.reload.delivery_contexts.fetch('old_completed')
    assert_equal 'queued', change.delivery_states.fetch('old_completed')
  end

  test 'abandonment is audited before old contact payload is deleted and contains no contacts' do
    change = create_change(completed: true, expires_at: 8.days.ago,
                           states: { 'old_completed' => 'error', 'new_completed' => 'queued' })
    old_value = change.old_value
    proposed_value = change.proposed_value
    original_log = AuditEventService.method(:log)
    observed_before_delete = false
    observe_log = lambda do |**options|
      if options[:action] == 'account_contact_notice_abandoned'
        assert ContactChangeRequest.exists?(change.id), 'The audit must precede deletion of its encrypted intent'
        observed_before_delete = true
      end
      original_log.call(**options)
    end
    AuditEventService.stub(:log, observe_log) do
      assert_difference -> { Event.where(action: 'account_contact_notice_abandoned', auditable: @user).count }, 1 do
        PruneContactVerificationsJob.perform_now
      end
    end
    assert observed_before_delete
    assert_not ContactChangeRequest.exists?(change.id)
    event = Event.find_by!(action: 'account_contact_notice_abandoned', auditable: @user)
    assert_equal change.id, event.metadata.fetch('contact_change_request_id')
    assert_equal({ 'old_completed' => 'error', 'new_completed' => 'queued' }, event.metadata.fetch('delivery_states'))
    assert_not_includes event.metadata.to_json, old_value
    assert_not_includes event.metadata.to_json, proposed_value
    assert User.exists?(@user.id)
    assert_no_difference -> { Event.where(action: 'account_contact_notice_abandoned', auditable: @user).count } do
      PruneContactVerificationsJob.perform_now
    end
  end

  test 'an abandonment audit failure retains the encrypted contact payload for retry' do
    change = create_change(completed: true, expires_at: 8.days.ago, states: { 'new_completed' => 'error' })
    old_value = change.old_value
    proposed_value = change.proposed_value
    AuditEventService.expects(:log).raises(ActiveRecord::RecordNotSaved)
    assert_raises(ActiveRecord::RecordNotSaved) { PruneContactVerificationsJob.perform_now }
    assert ContactChangeRequest.exists?(change.id)
    assert_equal old_value, change.reload.old_value
    assert_equal proposed_value, change.proposed_value
    assert_equal 'error', change.delivery_states.fetch('new_completed')
    assert_not Event.exists?(action: 'account_contact_notice_abandoned', auditable: @user)
  end

  test 'old SMS payload expires independently while a live ownership lease remains' do
    phone = "410#{SecureRandom.random_number(8_000_000) + 2_000_000}"
    attributes = { destination_digest: AuthRateLimit.contact_digest(phone), phone_number: phone,
                   purpose: 'contact_change', owner_digest: SmsVerificationAttempt.digest_owner('retention-fixture') }
    old = SmsVerificationAttempt.create!(**attributes, service_sid: "VA-old-#{SecureRandom.hex(5)}",
                                                       issued_at: 2.days.ago, expires_at: 2.days.ago + SmsVerificationAttempt::TTL,
                                                       ownership_expires_at: 2.days.ago + SmsVerificationAttempt::TTL + SmsVerificationAttempt::CALL_TIMEOUT)
    live = SmsVerificationAttempt.create!(**attributes, service_sid: "VA-live-#{SecureRandom.hex(5)}",
                                                        issued_at: Time.current, expires_at: SmsVerificationAttempt::TTL.from_now,
                                                        ownership_expires_at: (SmsVerificationAttempt::TTL + SmsVerificationAttempt::CALL_TIMEOUT).from_now)
    retained = SmsVerificationAttempt.create!(**attributes, service_sid: "VA-retained-#{SecureRandom.hex(5)}",
                                                            issued_at: 26.hours.ago, expires_at: 26.hours.ago + SmsVerificationAttempt::TTL,
                                                            ownership_expires_at: 2.hours.ago)
    PruneContactVerificationsJob.perform_now
    assert_not SmsVerificationAttempt.exists?(old.id)
    assert SmsVerificationAttempt.exists?(live.id)
    assert SmsVerificationAttempt.exists?(retained.id), 'Retention starts at provider ownership expiry, not local code expiry'
    assert User.exists?(@user.id)
  end

  private

  def create_change(completed: false, expires_at: 20.minutes.from_now, states: {})
    change = @writer.request!(kind: 'email', proposed_value: "retained-contact-#{SecureRandom.hex(5)}@example.com")
    if completed
      change.update!(old_confirmed_at: Time.current, new_confirmed_at: Time.current)
      @writer.complete!(change)
    end
    change.update!(expires_at: expires_at, delivery_states: change.delivery_states.transform_values { 'submitted' }.merge(states))
    change.reload
  end
end
