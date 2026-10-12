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
      @evaluation.application.with_lock do
        @evaluation.with_lock do
          prepare_evaluation
          save_evaluation!
          create_event!
        end
      end

      # The submission is committed; a confirmation that cannot be queued does not undo it.
      notification = notify_constituent

      success('Evaluation submitted successfully.', { evaluation: @evaluation, notification: notification })
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
      @evaluation.report_submitted_at = Time.current
      @evaluation.report_submitted = true
    end

    def validate_status!
      raise ArgumentError, 'Only the assigned evaluator can update this evaluation.' unless @evaluation.evaluator_id == @actor&.id

      return if @evaluation.can_complete?

      raise ArgumentError, 'Only scheduled or confirmed evaluations can be completed.'
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
          appointment_completed_at: @evaluation.appointment_completed_at&.iso8601,
          report_submitted_at: @evaluation.report_submitted_at&.iso8601,
          products_tried_count: @evaluation.products_tried.size,
          recommended_products_count: @evaluation.recommended_product_ids.size,
          recommended_product_ids: @evaluation.recommended_product_ids,
          recommended_product_names: @evaluation.recommended_products.map(&:name),
          recommendation_outcome: @evaluation.recommendation_outcome,
          timestamp: Time.current.iso8601
        }
      )
    end

    def submission_params
      attributes = @params.require(:evaluation).permit(
        :needs,
        :location,
        :notes,
        :appointment_completed_at,
        :attendees_field,
        :recommendation_outcome,
        :recommendation_notes,
        recommended_product_ids: [],
        products_tried_field: [],
        attendees: %i[name relationship],
        products_tried: %i[product_id reaction]
      )
      if %w[outside_catalog no_suitable_product].include?(attributes[:recommendation_outcome]) &&
         !attributes.key?(:recommended_product_ids)
        attributes[:recommended_product_ids] = []
      end
      attributes
    end

    def notify_constituent
      outcome = EmailDelivery.deliver_later(EvaluatorMailer.with(evaluation: @evaluation).evaluation_submission_confirmation)
      record_confirmation_enqueue_failure('ActiveJob::EnqueueError') if outcome == :enqueue_failed
      outcome
    rescue StandardError => e
      record_confirmation_enqueue_failure(e.class.name)
      :enqueue_failed
    end

    def record_confirmation_enqueue_failure(error_class)
      Rails.logger.error("Evaluation submission confirmation not queued for evaluation #{@evaluation.id}: #{error_class}")
      AuditEventService.log(
        action: 'evaluation_submission_confirmation_enqueue_failed',
        actor: @actor,
        auditable: @evaluation,
        metadata: { error_class: error_class }
      )
    end
  end
end
