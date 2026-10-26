# frozen_string_literal: true

module Evaluations
  class SubmissionService < BaseService
    REPORT_PARAMETERS = [
      :assessment_source, :appointment_completed_at, :location, :notes, :attendees_field,
      :no_suitable_product, :recommendation_notes,
      { recommended_product_ids: [].freeze, products_tried_inputs: [%i[selected reaction].freeze].freeze }.freeze
    ].freeze
    REPORT_FIELDS = REPORT_PARAMETERS.flat_map { |parameter| parameter.is_a?(Hash) ? parameter.keys : parameter }.freeze

    def self.report_params(params)
      attributes = params.expect(evaluation: REPORT_PARAMETERS)
      raise ActionController::BadRequest, 'Product trials must be keyed by catalog product ID.' if attributes[:products_tried_inputs].is_a?(Array)

      attributes
    end

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
          EquipmentNeeds::Writer.initialize_from!(@evaluation, actor: @actor)
          create_event!
        end
      end

      # The submission is committed; a confirmation that cannot be queued does not undo it.
      notification = notify_constituent

      success('Evaluation submitted successfully.', { evaluation: @evaluation, notification: notification })
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error "Evaluation submission failed for ID #{@evaluation&.id}: #{e.class.name}"
      failure(e.message)
    rescue ArgumentError => e
      Rails.logger.warn("Evaluations::SubmissionService validation failed: #{e.class.name}")
      failure(e.message)
    rescue Equipment::Conflict => e
      failure(e.message)
    end

    private

    def prepare_evaluation
      @evaluation.errors.clear
      attributes = submission_params
      validate_status!(attributes[:assessment_source])
      @evaluation.assign_attributes(attributes)
      @evaluation.status = :completed
      @evaluation.report_submitted_at = Time.current
    end

    def validate_status!(source)
      raise ArgumentError, 'Only the assigned evaluator can update this evaluation.' unless @evaluation.evaluator_id == @actor&.id

      @evaluation.require_approved_application!
      if source == 'outside_specialist' && !@evaluation.outside_specialist_report_allowed?(@actor)
        raise ArgumentError, 'Outside-specialist reports are only available to the assigned administrator.'
      end

      return if @evaluation.report_completion_allowed?(actor: @actor, source: source)

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
          assessment_source: @evaluation.assessment_source,
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
      attributes = self.class.report_params(@params)
      attributes[:assessment_source] = 'direct_assessment' unless attributes.key?(:assessment_source)
      unless Evaluation.assessment_sources.key?(attributes[:assessment_source])
        @evaluation.errors.add(:assessment_source, 'must be selected')
        raise ActiveRecord::RecordInvalid, @evaluation
      end
      attributes[:recommended_product_ids] = Array(attributes[:recommended_product_ids]).compact_blank
      attributes[:products_tried_inputs] ||= {}
      no_suitable_product = ActiveModel::Type::Boolean.new.cast(attributes.delete(:no_suitable_product).presence)
      if no_suitable_product && attributes[:recommended_product_ids].any?
        @evaluation.errors.add(:no_suitable_product, 'cannot be combined with catalog recommendations')
        raise ActiveRecord::RecordInvalid, @evaluation
      end
      if !no_suitable_product && attributes[:recommended_product_ids].empty? && attributes[:recommendation_notes].blank?
        @evaluation.errors.add(:recommended_products, 'must be selected, or enter another recommendation or choose no suitable product')
        raise ActiveRecord::RecordInvalid, @evaluation
      end
      attributes[:recommendation_outcome] = if no_suitable_product
                                              'no_suitable_product'
                                            elsif attributes[:recommended_product_ids].any?
                                              'catalog_products'
                                            else
                                              'outside_catalog'
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
