# frozen_string_literal: true

module TrainingSessions
  class RescheduleService < BaseService
    def initialize(training_session, current_user, params)
      super()
      @training_session = training_session
      @actor = current_user
      @params = params
    end

    def call
      @training_session.with_current_trainer_lock(@actor) do
        validate_transition!
        old_scheduled_for = @training_session.scheduled_for
        @training_session.assign_attributes(scheduled_for: @params[:scheduled_for], reschedule_reason: @params[:reschedule_reason],
                                            location: @params[:location], status: :scheduled)
        if @training_session.scheduled_for == old_scheduled_for
          @training_session.errors.add(:scheduled_for, I18n.t('training_rules.changed_date_required'))
          raise ActiveRecord::RecordInvalid, @training_session
        end

        @training_session.save!
        AuditEventService.log(
          actor: @actor, action: 'training_rescheduled', auditable: @training_session,
          metadata: { application_id: @training_session.application_id, training_session_id: @training_session.id,
                      old_scheduled_for: old_scheduled_for.iso8601, new_scheduled_for: @training_session.scheduled_for.iso8601,
                      initiator: 'constituent' }
        )
        @notification_outcome = TrainingSessionNotifier.new(
          @training_session, actor: @actor, action: 'training_rescheduled', old_scheduled_for: old_scheduled_for
        ).deliver_after_commit
      end
      success(I18n.t('training_rules.rescheduled'), { training_session: @training_session, notification_outcome: @notification_outcome })
    rescue ActiveRecord::RecordInvalid => e
      failure(e.record.errors.full_messages.to_sentence, { training_session: @training_session })
    rescue OperationError => e
      failure(e.message, { training_session: @training_session })
    end

    private

    def validate_transition!
      raise OperationError, I18n.t('training_rules.reschedulable_session_only') unless @training_session.can_reschedule_current_session?
      return if @params[:reschedule_reason].present?

      @training_session.errors.add(:reschedule_reason, I18n.t('training_rules.reschedule_reason_required'))
      raise ActiveRecord::RecordInvalid, @training_session
    end
  end
end
