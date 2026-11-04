# frozen_string_literal: true

class ProofReviewReminderJob < ApplicationJob
  queue_as :default
  retry_on ActiveJob::EnqueueError, wait: :polynomially_longer, attempts: 3

  MAIL_ACTION = 'ApplicationNotificationsMailer#proof_needs_review_reminder'

  def perform
    applications = Application.awaiting_proof_review.where(needs_review_since: ...3.days.ago).includes(:user).to_a
    return if applications.empty?

    actor = PublicAuditActor.system_audit_actor!
    User.admins.where.not(id: actor.id).find_each do |admin|
      notification = reminder_for(admin, applications, actor)
      next if notification.delivery_status.present? && !notification.error_delivery_status?
      next if notification.email_delivery_attempts.exists?

      context = notification.metadata.fetch('review_delivery_context')
      delivery = ApplicationNotificationsMailer.with(notification_id: notification.id).proof_needs_review_reminder(admin, applications)
      outcome = EmailDelivery.deliver_later(delivery, context: context)
      raise ActiveJob::EnqueueError, 'Proof review reminder could not be queued' if outcome == :enqueue_failed
    end
  end

  private

  # The recipient lock serializes this job's daily identity; retries reuse its control snapshot.
  def reminder_for(admin, applications, actor)
    admin.with_lock do
      existing = Notification.where(recipient: admin, action: 'proof_needs_review_reminder')
                             .where("metadata->>'reminder_date' = ?", Date.current.iso8601).first
      if existing
        existing
      else
        notification = NotificationService.create_and_deliver!(
          type: 'proof_needs_review_reminder', recipient: admin, actor: actor, notifiable: admin, deliver: false,
          metadata: { reminder_date: Date.current.iso8601, application_ids: applications.map(&:id) }
        )
        context = EmailDelivery::Policy.capture(mail_action: MAIL_ACTION, params: { notification_id: notification.id })
        notification.update_metadata!('review_delivery_context', context)
        notification
      end
    end
  end
end
