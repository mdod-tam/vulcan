# frozen_string_literal: true

module Evaluations
  class NoShowService < BaseService
    def initialize(evaluation, actor, params)
      super()
      @evaluation = evaluation
      @actor = actor
      @params = params
    end

    def call
      validate_transition!

      ApplicationRecord.transaction do
        @evaluation.update!(
          status: :no_show,
          notes: no_show_notes
        )
        create_event!
      end

      success(I18n.t('evaluations.no_show.success'), { evaluation: @evaluation })
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error("Error marking evaluation as no-show: #{e.message}")
      failure(e.message)
    rescue ArgumentError => e
      Rails.logger.warn("Evaluations::NoShowService validation failed: #{e.message}")
      failure(e.message)
    end

    private

    def validate_transition!
      raise ArgumentError, I18n.t('evaluations.no_show.wrong_status') unless @evaluation.status_scheduled? || @evaluation.status_confirmed?
      raise ArgumentError, I18n.t('evaluations.no_show.scheduled_time_required') if @evaluation.evaluation_date.blank?
      raise ArgumentError, I18n.t('evaluations.no_show.scheduled_time_in_future') if @evaluation.evaluation_date.future?
    end

    def no_show_notes
      @params[:notes].presence
    end

    def create_event!
      AuditEventService.log(
        action: 'evaluation_no_show',
        actor: @actor,
        auditable: @evaluation,
        metadata: {
          evaluation_id: @evaluation.id,
          application_id: @evaluation.application_id,
          evaluation_date: @evaluation.evaluation_date&.iso8601,
          no_show_notes: no_show_notes,
          timestamp: Time.current.iso8601
        }
      )
    end
  end
end
