# frozen_string_literal: true

module TrainingSessions
  class CancelService < BaseService
    def initialize(training_session, current_user, params)
      super()
      @training_session = training_session
      @actor = current_user
      @params = params
      @cancellation_initiator = params[:cancellation_initiator]
    end

    def call
      @training_session.with_current_trainer_lock(@actor) do
        raise OperationError, I18n.t('training_sessions.cancel.invalid_status') unless @training_session.can_cancel?

        validate_params!
        initiator = @cancellation_initiator
        # A new operation id supersedes any transfer notice still queued for the row.
        @training_session.update!(status: :cancelled, cancelled_at: Time.current, assignment_operation_id: SecureRandom.uuid,
                                  cancellation_reason: @params[:cancellation_reason], cancellation_initiator: initiator)
        AuditEventService.log(
          actor: @actor, action: 'training_cancelled', auditable: @training_session,
          metadata: { application_id: @training_session.application_id, training_session_id: @training_session.id,
                      cancellation_initiator: @training_session.cancellation_initiator }
        )
        @notification_outcome = TrainingSessionNotifier.new(
          @training_session, actor: @actor, action: 'training_cancelled'
        ).deliver_after_commit
      end
      success(I18n.t('training_sessions.cancel.success'), { training_session: @training_session, notification_outcome: @notification_outcome })
    rescue ActiveRecord::RecordInvalid => e
      failure(e.record.errors.full_messages.to_sentence, { training_session: @training_session })
    rescue OperationError => e
      failure(e.message, { training_session: @training_session })
    end

    private

    def validate_params!
      @training_session.errors.add(:cancellation_reason, :blank) if @params[:cancellation_reason].blank?
      unless %w[constituent trainer program].include?(@cancellation_initiator.to_s)
        @training_session.errors.add(:cancellation_initiator, I18n.t('training_rules.cancellation_initiator_required'))
      end
      raise ActiveRecord::RecordInvalid, @training_session if @training_session.errors.any?
    end
  end
end
