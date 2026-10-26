# frozen_string_literal: true

# Alerts administrators when the share of failed proof attachments over the last 24 hours is high.
# config/recurring.yml schedules it.
class ProofAttachmentMetricsJob < ApplicationJob
  queue_as :low

  # Alert when the success rate falls below this percentage and at least MINIMUM_FAILURES_THRESHOLD attachments failed.
  SUCCESS_RATE_THRESHOLD = 95.0
  MINIMUM_FAILURES_THRESHOLD = 5

  def perform
    Rails.logger.info 'Analyzing Proof Submission Failure Rates'

    attachment_actions = %w[
      income_proof_attached residency_proof_attached
      income_proof_attachment_failed residency_proof_attachment_failed
    ]

    recent_events = Event.where(action: attachment_actions)
                         .where('created_at > ?', 24.hours.ago)

    total_submissions = recent_events.count
    failed_submissions = recent_events.where("action LIKE '%_failed'").count
    successful_submissions = total_submissions - failed_submissions

    success_rate = if total_submissions.positive?
                     (successful_submissions.to_f / total_submissions * 100).round(1)
                   else
                     100.0
                   end

    Rails.logger.info 'Proof Submission Analysis (Last 24 Hours): ' \
                      "Total: #{total_submissions}, " \
                      "Successful: #{successful_submissions}, " \
                      "Failed: #{failed_submissions}, " \
                      "Success Rate: #{success_rate}%"

    alert_administrators(success_rate, total_submissions, failed_submissions) if success_rate < SUCCESS_RATE_THRESHOLD && failed_submissions >= MINIMUM_FAILURES_THRESHOLD

    Rails.logger.info 'Proof submission failure rate analysis completed'
  end

  private

  def alert_administrators(success_rate, total, failed)
    Rails.logger.warn "High proof submission failure rate detected: #{success_rate}% (#{failed}/#{total})"

    current_system_user = User.system_user
    return unless current_system_user

    current_admins = User.where(type: 'Users::Administrator')
    Rails.logger.debug { "ProofAttachmentMetricsJob: Found #{current_admins.count} administrators." }

    current_admins.find_each do |admin|
      Rails.logger.debug { "ProofAttachmentMetricsJob: Attempting to create notification for admin #{admin.id}." }
      NotificationService.create_and_deliver!(
        type: 'attachment_failure_warning',
        recipient: admin,
        actor: current_system_user,
        notifiable: current_system_user,
        metadata: {
          success_rate: success_rate,
          total: total,
          failed: failed,
          threshold: SUCCESS_RATE_THRESHOLD,
          analysis_period: '24_hours'
        },
        audit: true,
        deliver: false
      )
    rescue StandardError => e
      Rails.logger.error "Failed to create failure warning notification for admin #{admin.id}: #{e.class.name}"
    end

    Rails.logger.info "Created failure rate warnings for #{current_admins.count} administrators"
  end
end
