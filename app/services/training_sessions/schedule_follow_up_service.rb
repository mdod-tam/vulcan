# frozen_string_literal: true

module TrainingSessions
  class ScheduleFollowUpService < BaseService
    def initialize(source_training_session, current_user, params)
      super()
      @source_training_session = source_training_session
      @current_user = current_user
      @params = params
    end

    def call
      validate_params!

      application.with_lock do
        validate_application_state!
        create_follow_up_session!
        create_event!
      end

      success(I18n.t('training_sessions.schedule_follow_up.success'), { training_session: @follow_up_session })
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error("Error scheduling follow-up training session: #{e.message}")
      failure(e.message)
    rescue ArgumentError => e
      Rails.logger.warn("TrainingSessions::ScheduleFollowUpService validation failed: #{e.message}")
      failure(e.message)
    rescue StandardError => e
      Rails.logger.error("Unexpected error scheduling follow-up training session: #{e.message}")
      failure(I18n.t('training_sessions.schedule_follow_up.unexpected_error', message: e.message))
    end

    private

    attr_reader :source_training_session

    def application
      @application ||= source_training_session.application
    end

    def validate_params!
      unless source_training_session.can_schedule_followup?
        raise ArgumentError, I18n.t('training_sessions.schedule_follow_up.invalid_source')
      end

      if @params[:scheduled_for].blank? || @params[:reschedule_reason].blank?
        raise ArgumentError, I18n.t('training_sessions.schedule_follow_up.missing_required_fields')
      end

      validate_scheduled_time!
    end

    def validate_application_state!
      raise ArgumentError, I18n.t('training_sessions.schedule_follow_up.service_window_closed') unless application.service_window_active?
      raise ArgumentError, I18n.t('training_sessions.schedule_follow_up.quota_exhausted') if application.training_session_quota_exhausted?
      raise ArgumentError, I18n.t('training_sessions.schedule_follow_up.active_session') if application.active_training_session_present?
    end

    def validate_scheduled_time!
      raise ArgumentError, I18n.t('training_sessions.schedule_follow_up.invalid_scheduled_for') unless scheduled_for
      return if scheduled_for > Time.current

      raise ArgumentError, I18n.t('training_sessions.schedule_follow_up.scheduled_for_in_future')
    end

    def scheduled_for
      @scheduled_for ||= case @params[:scheduled_for]
                         when Time, ActiveSupport::TimeWithZone
                           @params[:scheduled_for]
                         else
                           Time.zone.parse(@params[:scheduled_for].to_s)
                         end
    rescue ArgumentError, TypeError
      nil
    end

    def create_follow_up_session!
      @follow_up_session = application.training_sessions.create!(
        trainer: source_training_session.trainer,
        status: :scheduled,
        scheduled_for: scheduled_for,
        location: @params[:location],
        reschedule_reason: @params[:reschedule_reason]
      )
    end

    def create_event!
      AuditEventService.log(
        actor: @current_user,
        action: 'training_followup_scheduled',
        auditable: @follow_up_session,
        metadata: {
          application_id: application.id,
          training_session_id: @follow_up_session.id,
          previous_training_session_id: source_training_session.id,
          previous_training_session_status: source_training_session.status,
          scheduled_for: @follow_up_session.scheduled_for&.iso8601,
          reason: @follow_up_session.reschedule_reason,
          location: @follow_up_session.location,
          timestamp: Time.current.iso8601
        }
      )
    end
  end
end
