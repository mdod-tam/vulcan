# frozen_string_literal: true

# Monitors proof submission failure rates and alerts administrators
# when failure rates exceed acceptable thresholds
# Scheduled via config/recurring.yml to run periodically
class ProofAttachmentMetricsJob < ApplicationJob
  queue_as :low

  # Thresholds for alerting
  SUCCESS_RATE_THRESHOLD = 95.0 # Alert if success rate falls below 95%
  MINIMUM_FAILURES_THRESHOLD = 5 # Only alert if we have at least 5 failures

  def perform
    Rails.logger.info 'Analyzing Proof Submission Failure Rates'

    # Define the relevant actions for attachment success and failure
    attachment_actions = %w[
      income_proof_attached residency_proof_attached
      income_proof_attachment_failed residency_proof_attachment_failed
    ]

    # Get recent proof attachment events (last 24 hours)
    recent_events = Event.where(action: attachment_actions)
                         .where('created_at > ?', 24.hours.ago)

    total_submissions = recent_events.count
    failed_submissions = recent_events.where("action LIKE '%_failed'").count
    successful_submissions = total_submissions - failed_submissions

    # Calculate success rate
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

    # Alert administrators if failure rate is too high
    alert_administrators(success_rate, total_submissions, failed_submissions) if success_rate < SUCCESS_RATE_THRESHOLD && failed_submissions >= MINIMUM_FAILURES_THRESHOLD

    Rails.logger.info 'Proof submission failure rate analysis completed'
  end

  private

  def alert_administrators(success_rate, total, failed)
    Rails.logger.warn "High proof submission failure rate detected: #{success_rate}% (#{failed}/#{total})"

    # Re-fetch system user and admins immediately before use to ensure they are current
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
        audit: true,    # Admin alerts should be audited
        deliver: false  # Don't attempt email delivery until mailer is configured
      )
    rescue StandardError => e
      Rails.logger.error "Failed to create failure warning notification for admin #{admin.id}: #{e.message}"
    end

    Rails.logger.info "Created failure rate warnings for #{current_admins.count} administrators"
  end
end
