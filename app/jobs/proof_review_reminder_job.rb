# frozen_string_literal: true

class ProofReviewReminderJob < ApplicationJob
  queue_as :default

  def perform
    Rails.logger.info('Running ProofReviewReminderJob')

    # Find applications that have been needing review for more than 3 days
    stale_applications = Application.where(needs_review_since: ...3.days.ago)
                                    .includes(:user, :proof_reviews)

    return if stale_applications.empty?

    User.where(type: 'Users::Administrator').find_each do |admin|
      ApplicationNotificationsMailer.proof_needs_review_reminder(admin, stale_applications.to_a).deliver_now
    end

    Rails.logger.info("Sent proof review reminders for #{stale_applications.count} applications")
  end
end
