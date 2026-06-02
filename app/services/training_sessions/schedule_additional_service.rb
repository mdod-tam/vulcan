# frozen_string_literal: true

module TrainingSessions
  class ScheduleAdditionalService < BaseService
    def initialize(source_training_session, current_user, params)
      super()
      @source_training_session = source_training_session
      @current_user = current_user
      @params = params
    end

    def call
      validate_source!
      validate_params!

      application.with_lock do
        validate_application_state!
        create_training_session!
        create_event!
      end

      success(I18n.t('training_sessions.schedule_additional.success'), { training_session: @training_session })
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error("Error scheduling additional training session: #{e.message}")
      failure(e.message)
    rescue ArgumentError => e
      Rails.logger.warn("TrainingSessions::ScheduleAdditionalService validation failed: #{e.message}")
      failure(e.message)
    rescue StandardError => e
      Rails.logger.error("Unexpected error scheduling additional training session: #{e.message}")
      failure(I18n.t('training_sessions.schedule_additional.unexpected_error', message: e.message))
    end

    private

    attr_reader :source_training_session

    def application
      @application ||= source_training_session.application
    end

    def validate_source!
      return if source_training_session.status_scheduled? ||
                source_training_session.status_confirmed? ||
                source_training_session.status_completed?

      raise ArgumentError, I18n.t('training_sessions.schedule_additional.invalid_source')
    end

    def validate_params!
      raise ArgumentError, I18n.t('training_sessions.schedule_additional.missing_scheduled_for') if @params[:scheduled_for].blank?
      raise ArgumentError, I18n.t('training_sessions.schedule_additional.invalid_scheduled_for') unless scheduled_for
      return if scheduled_for > Time.current

      raise ArgumentError, I18n.t('training_sessions.schedule_additional.scheduled_for_in_future')
    end

    def validate_application_state!
      raise ArgumentError, I18n.t('training_sessions.schedule_additional.service_window_closed') unless application.service_window_active?
      return unless application.training_session_quota_exhausted?

      raise ArgumentError, I18n.t('training_sessions.schedule_additional.quota_exhausted')
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

    def create_training_session!
      @training_session = application.training_sessions.create!(
        trainer: source_training_session.trainer,
        status: :scheduled,
        scheduled_for: scheduled_for,
        location: @params[:location],
        notes: @params[:notes]
      )
    end

    def create_event!
      AuditEventService.log(
        actor: @current_user,
        action: 'training_scheduled',
        auditable: @training_session,
        metadata: {
          application_id: application.id,
          training_session_id: @training_session.id,
          source_training_session_id: source_training_session.id,
          scheduled_via: 'additional',
          scheduled_for: @training_session.scheduled_for&.iso8601,
          notes: @training_session.notes,
          location: @training_session.location,
          timestamp: Time.current.iso8601
        }
      )
    end
  end
end
