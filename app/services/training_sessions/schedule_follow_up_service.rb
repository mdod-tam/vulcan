# frozen_string_literal: true

module TrainingSessions
  class ScheduleFollowUpService < BaseService
    def initialize(source_training_session, current_user, params)
      super()
      @source_training_session = source_training_session
      @actor = current_user
      @params = params
    end

    def call
      source = @source_training_session
      application = source.application
      source.with_current_trainer_lock(@actor) do
        eligibility_error = application.new_training_work_eligibility_error(actor: @actor, source: source)
        raise ArgumentError, eligibility_error if eligibility_error
        raise ArgumentError, I18n.t('training_sessions.schedule_follow_up.invalid_source') unless application.latest_training_follow_up_session&.id == source.id

        if @params[:reschedule_reason].blank?
          source.errors.add(:reschedule_reason, I18n.t('training_rules.follow_up_reason_required'))
          raise ActiveRecord::RecordInvalid, source
        end

        @training_session = application.training_sessions.create!(
          trainer: application.assigned_trainer, status: :scheduled, scheduled_for: @params[:scheduled_for],
          location: @params[:location], internal_notes: @params[:internal_notes], reschedule_reason: @params[:reschedule_reason]
        )
        AuditEventService.log(
          actor: @actor, action: 'training_followup_scheduled', auditable: @training_session,
          metadata: { application_id: application.id, training_session_id: @training_session.id,
                      previous_training_session_id: source.id, previous_training_session_status: source.status,
                      scheduled_for: @training_session.scheduled_for.iso8601 }
        )
        @notification_outcome = TrainingSessionNotifier.new(
          @training_session, actor: @actor, action: 'training_scheduled'
        ).deliver_after_commit
      end
      success(I18n.t('training_sessions.schedule_follow_up.success'), { training_session: @training_session, notification_outcome: @notification_outcome })
    rescue ActiveRecord::RecordInvalid => e
      failure(e.record.errors.full_messages.to_sentence, { training_session: e.record })
    rescue ArgumentError => e
      failure(e.message)
    end
  end
end
