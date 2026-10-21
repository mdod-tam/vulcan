# frozen_string_literal: true

module TrainingSessions
  class CompleteService < BaseService
    def initialize(training_session, current_user, params)
      super()
      @training_session = training_session
      @actor = current_user
      @params = params
    end

    def call
      @training_session.with_current_trainer_lock(@actor) do
        raise OperationError, I18n.t('training_sessions.complete.invalid_status') unless @training_session.can_complete?

        attributes = {
          status: :completed, completed_at: @params[:completed_at], report_submitted_at: Time.current,
          constituent_summary: @params[:constituent_summary], summary_locale: @params[:summary_locale],
          product_trained_on_id: @params[:product_trained_on_id], duration_hours: @params[:duration_hours]
        }
        attributes[:internal_notes] = @params[:internal_notes] if @params.key?(:internal_notes)
        @training_session.update!(attributes)
        AuditEventService.log(
          actor: @actor, action: 'training_completed', auditable: @training_session,
          metadata: { application_id: @training_session.application_id, training_session_id: @training_session.id,
                      completed_at: @training_session.completed_at.iso8601, report_submitted_at: @training_session.report_submitted_at.iso8601,
                      duration_hours: @training_session.duration_hours.to_s('F'), product_trained_on_id: @training_session.product_trained_on_id,
                      summary_locale: @training_session.summary_locale }
        )
        @notification_outcome = TrainingSessionNotifier.new(
          @training_session, actor: @actor, action: 'training_completed'
        ).deliver_after_commit
      end
      success(I18n.t('training_sessions.complete.success'), { training_session: @training_session, notification_outcome: @notification_outcome })
    rescue ActiveRecord::RecordInvalid => e
      failure(e.record.errors.full_messages.to_sentence, { training_session: @training_session })
    rescue OperationError => e
      failure(e.message, { training_session: @training_session })
    end
  end
end
