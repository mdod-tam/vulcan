# frozen_string_literal: true

module TrainingSessions
  class NoShowService < BaseService
    def initialize(training_session, current_user, params)
      super()
      @training_session = training_session
      @actor = current_user
      @params = params
    end

    def call
      @training_session.with_current_trainer_lock(@actor) do
        unless @training_session.can_complete? && @training_session.scheduled_for.present? && @training_session.scheduled_for <= Time.current
          raise ArgumentError, I18n.t('training_rules.no_show_after_start')
        end

        @training_session.update!(status: :no_show, no_show_notes: @params[:no_show_notes])
        AuditEventService.log(
          actor: @actor, action: 'training_no_show', auditable: @training_session,
          metadata: { application_id: @training_session.application_id, training_session_id: @training_session.id,
                      scheduled_for: @training_session.scheduled_for.iso8601 }
        )
        @notification_outcome = TrainingSessionNotifier.new(
          @training_session, actor: @actor, action: 'training_missed'
        ).deliver_after_commit
      end
      success(I18n.t('training_rules.no_show_recorded'), { training_session: @training_session, notification_outcome: @notification_outcome })
    rescue ActiveRecord::RecordInvalid => e
      failure(e.record.errors.full_messages.to_sentence, { training_session: @training_session })
    rescue ArgumentError => e
      failure(e.message, { training_session: @training_session })
    end
  end
end
