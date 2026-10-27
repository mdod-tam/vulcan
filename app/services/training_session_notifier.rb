# frozen_string_literal: true

class TrainingSessionNotifier
  ACTIONS = %w[trainer_assigned trainer_reassigned training_trainer_changed training_scheduled training_rescheduled training_cancelled
               training_missed training_completed].freeze
  TRAINER_ADDRESSED_ACTIONS = %w[trainer_assigned trainer_reassigned].freeze
  DeliveryOutcome = Struct.new(:status, :notification_id, :error_class, keyword_init: true) do
    def warning? = %i[failed suppressed].include?(status)
  end

  def initialize(training_session, actor:, action:, old_scheduled_for: nil)
    raise ArgumentError, 'Unknown training notification action' unless ACTIONS.include?(action.to_s)

    @training_session = training_session
    @actor = actor
    @action = action.to_s
    @recipient = TRAINER_ADDRESSED_ACTIONS.include?(@action) ? training_session.trainer : training_session.constituent
    @metadata = {
      training_session_id: training_session.id,
      application_id: training_session.application_id,
      status: training_session.status,
      old_scheduled_for: old_scheduled_for&.iso8601,
      scheduled_for: training_session.scheduled_for&.iso8601,
      completed_at: training_session.completed_at&.iso8601,
      cancellation_initiator: training_session.cancellation_initiator,
      trainer_name: training_session.trainer.full_name,
      location: training_session.location
    }
    # An assignment notice carries its operation, so the delivery guard can supersede it after a later transfer.
    @metadata[:operation_id] = training_session.assignment_operation_id if EmailDelivery::Catalog.notification_action(@action).adapter == :assignment
    @metadata.freeze
  end

  def deliver_after_commit
    outcome = DeliveryOutcome.new(status: :deferred)
    ActiveRecord.after_all_transactions_commit { deliver(outcome) }
    outcome
  end

  private

  def deliver(outcome)
    notification = NotificationService.create_and_deliver!(
      type: @action,
      recipient: @recipient,
      actor: @actor,
      notifiable: @training_session,
      metadata: @metadata,
      channel: :email
    )
    outcome.notification_id = notification&.id
    outcome.status = NotificationService.delivery_outcome(notification)
  rescue StandardError => e
    outcome.status = :failed
    outcome.error_class = e.class.name
    Rails.logger.error("Training notification failed (training_session_id=#{@training_session.id}, action=#{@action}, error_class=#{e.class.name})")
  end
end
