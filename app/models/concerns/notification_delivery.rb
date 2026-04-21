# frozen_string_literal: true

module NotificationDelivery
  extend ActiveSupport::Concern

  included do |_base|
    # Use after_commit instead of after_create_commit to ensure all changes are committed first
    # This helps prevent infinite recursion by ensuring the transaction is complete
    after_commit :deliver_notifications, on: :create
  end

  def deliver_notifications
    # Guard clause to prevent infinite recursion
    return if @delivering_notifications
    return unless should_deliver_notifications?

    # Set flag to prevent reentry during delivery
    @delivering_notifications = true

    begin
      # Use the appropriate mailer based on the model type
      case self
      when TrainingSession
        TrainingSessionNotifier.new(self).deliver_all
      else
        Rails.logger.warn("No notification handler defined for #{self.class.name}")
      end
    rescue StandardError => e
      log_delivery_error(e)
      # Re-raise the error to trigger Rails' retry mechanism
      raise
    ensure
      # Always reset the flag, even if an exception occurs
      @delivering_notifications = false
    end
  end

  private

  def should_deliver_notifications?
    # Skip notifications in test environment unless explicitly required
    return false if Rails.env.test? && !Thread.current[:force_notifications]

    status_changed? ||
      (respond_to?(:income_proof_status_changed?) && income_proof_status_changed?) ||
      (respond_to?(:residency_proof_status_changed?) && residency_proof_status_changed?)
  end

  def log_delivery_error(error)
    Rails.logger.error("Notification delivery failed: #{error.message}")
    Rails.logger.error("Record: #{self.class.name}, ID: #{id}")
    Rails.logger.error("Error details: #{error.backtrace.join("\n")}")
  end
end
