# frozen_string_literal: true

module Evaluations
  class SubmissionService < BaseService
    def initialize(evaluation, params, actor: nil)
      super()
      @evaluation = evaluation
      @params = params
      @actor = actor || evaluation.evaluator
    end

    def call
      ApplicationRecord.transaction do
        prepare_evaluation
        save_evaluation!
        create_event!
        notify_constituent
      end

      success(I18n.t('evaluations.complete.success'), { evaluation: @evaluation })
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error "Evaluation submission FAILED for ID #{@evaluation&.id}: #{e.message}"
      failure(e.message)
    rescue ArgumentError => e
      Rails.logger.warn("Evaluations::SubmissionService validation failed: #{e.message}")
      failure(e.message)
    end

    private

    def prepare_evaluation
      validate_status!
      @evaluation.assign_attributes(submission_params)
      @evaluation.status = :completed
    end

    def validate_status!
      return if @evaluation.can_complete?

      raise ArgumentError, I18n.t('evaluations.complete.wrong_status')
    end

    def save_evaluation!
      @evaluation.save!
    end

    def create_event!
      AuditEventService.log(
        action: 'evaluation_completed',
        actor: @actor,
        auditable: @evaluation,
        metadata: {
          evaluation_id: @evaluation.id,
          application_id: @evaluation.application_id,
          evaluation_date: @evaluation.evaluation_date&.iso8601,
          products_tried_count: @evaluation.products_tried.size,
          recommended_products_count: @evaluation.recommended_product_ids.size,
          recommended_product_ids: @evaluation.recommended_product_ids,
          recommended_product_names: @evaluation.recommended_products.map(&:name),
          timestamp: Time.current.iso8601
        }
      )
    end

    def submission_params
      @params.require(:evaluation).permit(
        :needs,
        :location,
        :notes,
        :evaluation_date,
        :attendees_field,
        recommended_product_ids: [],
        products_tried_field: [],
        attendees: %i[name relationship],
        products_tried: %i[product_id reaction]
      )
    end

    def notify_constituent
      EvaluatorMailer.evaluation_submission_confirmation(@evaluation).deliver_later
    end
  end
end
