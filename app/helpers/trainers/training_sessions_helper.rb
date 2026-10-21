# frozen_string_literal: true

module Trainers
  module TrainingSessionsHelper
    def training_form_value(action, field, default = nil, form_values:)
      form_values.fetch(action, {}).fetch(field, default)
    end

    def training_form_aria(action, field, form_errors:, describedby: nil)
      action_form_field_aria(action, field, form_errors: form_errors, describedby: describedby)
    end

    def training_required_label(text)
      safe_join([text, tag.span(t('trainer_workflow.forms.required'), class: 'text-sm font-normal')], ' ')
    end

    def training_completion_time_default(session)
      completed_at = session.completed_at || (session.scheduled_for if session.scheduled_for&.past?)
      completed_at&.strftime('%Y-%m-%dT%H:%M')
    end

    def training_action_url(action, session)
      case action
      when :schedule then schedule_trainers_training_session_path(session)
      when :complete then complete_trainers_training_session_path(session)
      when :cancel then cancel_trainers_training_session_path(session)
      when :no_show then no_show_trainers_training_session_path(session)
      when :reschedule then reschedule_trainers_training_session_path(session)
      when :schedule_additional then schedule_additional_trainers_training_session_path(session)
      when :follow_up then trainers_training_session_follow_up_path(session)
      end
    end

    def training_available_actions(session, can_manage:)
      return [] unless can_manage
      return %i[schedule cancel] if session.status_requested?
      return [] unless session.status_scheduled? || session.status_confirmed?

      actions = %i[complete reschedule cancel]
      actions << :no_show if session.scheduled_for.present? && session.scheduled_for <= Time.current
      actions
    end

    def training_outcome_options(session, can_manage:)
      training_available_actions(session, can_manage: can_manage).map do |action|
        [t("trainer_workflow.actions.#{action}"), action]
      end
    end

    def training_next_action(session, can_manage:, actor:)
      return unless can_manage
      return :follow_up if session.application.latest_training_follow_up_session&.id == session.id
      return :schedule_additional if session.application.additional_training_session_eligible?(session, actor: actor)

      nil
    end

    def training_next_action_unavailable_reason(session, can_manage:, actor:)
      return unless can_manage && (session.status_completed? || session.needs_followup?)
      return unless session.application.latest_training_session&.id == session.id
      return if training_next_action(session, can_manage: can_manage, actor: actor)

      session.application.new_training_work_eligibility_error(actor: actor, source: session)
    end
  end
end
