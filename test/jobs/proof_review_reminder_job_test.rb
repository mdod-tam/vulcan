# frozen_string_literal: true

require 'test_helper'

class ProofReviewReminderJobTest < ActiveJob::TestCase
  setup do
    DatabaseCleaner.clean
    Current.reset
    @actor = ensure_system_audit_actor!
    @admin = create(:admin)
    load_seeded_email_templates('application_notifications_proof_needs_review_reminder')
    ActionMailer::Base.deliveries.clear
  end

  teardown { DatabaseCleaner.clean_with(:truncation) }

  test 'stale pending proofs notify human admins once per day and reviewed proofs leave the backlog' do
    pending = create(:application, :in_progress, :with_residency_proof)
    reviewed = create(:application, :in_progress, :with_residency_proof)
    [pending, reviewed].each { |application| application.update_columns(needs_review_since: 4.days.ago) }
    reviewed.update!(residency_proof_status: :approved)
    assert_nil reviewed.reload.needs_review_since
    assert_includes Application.awaiting_proof_review, pending
    assert_not_includes Application.awaiting_proof_review, reviewed

    expected_recipients = User.admins.where.not(id: @actor.id).pluck(:email).sort
    perform_enqueued_jobs { 2.times { ProofReviewReminderJob.perform_now } }
    assert_equal expected_recipients, ActionMailer::Base.deliveries.flat_map(&:to).sort
    notification = Notification.find_by!(action: 'proof_needs_review_reminder', recipient: @admin)
    assert_equal [pending.id], notification.metadata['application_ids']
    assert_equal @actor, notification.actor
    assert_not Notification.exists?(action: 'proof_needs_review_reminder', recipient: pending.user)

    pending.update!(residency_proof_status: :rejected)
    assert_nil pending.reload.needs_review_since
    assert_no_difference ['Notification.count', 'ActionMailer::Base.deliveries.size'] do
      perform_enqueued_jobs { ProofReviewReminderJob.perform_now }
    end
  end

  test 'an enqueue retry reuses the daily notification and captured delivery identity' do
    application = create(:application, :in_progress, :with_residency_proof)
    application.update_column(:needs_review_since, 4.days.ago)
    original = EmailDelivery.method(:deliver_later)
    first = true
    enqueue = lambda do |delivery, **options|
      if first
        first = false
        :enqueue_failed
      else
        original.call(delivery, **options)
      end
    end
    EmailDelivery.stub(:deliver_later, enqueue) do
      assert_raises(ActiveJob::EnqueueError) { ProofReviewReminderJob.new.perform }
      notification = Notification.find_by!(action: 'proof_needs_review_reminder')
      context = notification.metadata.fetch('review_delivery_context')
      perform_enqueued_jobs { ProofReviewReminderJob.new.perform }
      assert_equal context, notification.reload.metadata.fetch('review_delivery_context')
      assert_equal 1, Notification.where(id: notification.id).count
    end
    expected = User.admins.where.not(id: @actor.id).pluck(:email).sort
    assert_equal expected, ActionMailer::Base.deliveries.flat_map(&:to).sort
  end

  test 'closed and inapplicable proofs leave no reminder while a later day can repeat open work' do
    closed = create(:application, :rejected, :with_residency_proof)
    inapplicable = create(:application, :in_progress, :with_income_proof)
    inapplicable.update!(income_proof_required: false)
    [closed, inapplicable].each { |application| application.update_column(:needs_review_since, 4.days.ago) }
    assert_no_difference('Notification.count') { ProofReviewReminderJob.perform_now }

    pending = create(:application, :in_progress, :with_residency_proof)
    pending.update_column(:needs_review_since, 4.days.ago)
    admins = User.admins.where.not(id: @actor.id).count
    assert_difference('Notification.count', admins * 2) do
      perform_enqueued_jobs { ProofReviewReminderJob.perform_now }
      travel 1.day do
        perform_enqueued_jobs { ProofReviewReminderJob.perform_now }
      end
    end
  end
end
