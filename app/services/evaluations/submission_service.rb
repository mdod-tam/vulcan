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
    end

    def validate_status!
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
