# frozen_string_literal: true

module TrainingSessions
  class ScheduleService < BaseService
    def initialize(training_session, current_user, params)
      super()
      @training_session = training_session
      @actor = current_user
      @params = params
    end

    def call
      @training_session.with_current_trainer_lock(@actor) do
        raise ArgumentError, I18n.t('training_rules.requested_schedule_only') unless @training_session.status_requested?
        raise ArgumentError, I18n.t('training_rules.schedule_service_window') unless @training_session.application.service_window_active?

        attributes = { status: :scheduled, scheduled_for: @params[:scheduled_for], location: @params[:location] }
        attributes[:internal_notes] = @params[:internal_notes] if @params.key?(:internal_notes)
        @training_session.update!(attributes)
        AuditEventService.log(
          actor: @actor, action: 'training_scheduled', auditable: @training_session,
          metadata: { application_id: @training_session.application_id, training_session_id: @training_session.id,
                      scheduled_for: @training_session.scheduled_for.iso8601 }
        )
        @notification_outcome = TrainingSessionNotifier.new(
          @training_session, actor: @actor, action: 'training_scheduled'
        ).deliver_after_commit
      end
      success(I18n.t('training_rules.scheduled'), { training_session: @training_session, notification_outcome: @notification_outcome })
    rescue ActiveRecord::RecordInvalid => e
      failure(e.record.errors.full_messages.to_sentence, { training_session: @training_session })
    rescue ArgumentError => e
      failure(e.message, { training_session: @training_session })
    end
  end
end
