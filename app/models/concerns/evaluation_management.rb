# frozen_string_literal: true

# Handles operations related to evaluation management
# This includes evaluator assignment and evaluation scheduling
module EvaluationManagement
  extend ActiveSupport::Concern

  REUSABLE_EVALUATION_STATUSES = %i[requested cancelled no_show rescheduled].freeze

  # Assigns an evaluator to this application
  # @param evaluator [Evaluator] The evaluator to assign
  # @return [Boolean] True if the evaluator was assigned successfully
  def assign_evaluator!(evaluator)
    unless service_window_active?
      errors.add(:base, :evaluation_service_window)
      return false
    end

    with_lock do
      if evaluations.exists?(status: :completed)
        errors.add(:base, :evaluation_assignment_closed)
        return false
      end

      evaluation = reusable_evaluation_for_assignment

      if evaluation
        # Reuse the row for lifecycle state only; preserve narrative notes because they may document constituent interactions.
        evaluation.update!(
          evaluator: evaluator,
          constituent: user,
          application: self,
          status: :requested,
          evaluation_date: nil,
          location: '',
          needs: '',
          products_tried: [],
          attendees: [],
          recommended_product_ids: [],
          report_submitted: false,
          reschedule_reason: nil
        )
      elsif evaluations.exists?
        errors.add(:base, :evaluation_assignment_closed)
        return false
      else
        evaluation = evaluations.create!(
          evaluator: evaluator,
          constituent: user,
          application: self,
          evaluation_type: determine_evaluation_type,
          evaluation_date: nil, # Will be set when scheduling
          needs: '',
          location: ''
          # Initialize other required fields as needed
        )
      end

      # Create event for audit logging
      AuditEventService.log(
        actor: Current.user,
        action: 'evaluator_assigned',
        auditable: self,
        metadata: {
          application_id: id,
          evaluator_id: evaluator.id,
          evaluator_name: evaluator.full_name,
          timestamp: Time.current.iso8601
        }
      )

      # Send email notification to evaluator
      EvaluatorMailer.with(
        evaluation: evaluation,
        constituent: user
      ).new_evaluation_assigned.deliver_later
    end
    true
  rescue ::ActiveRecord::RecordInvalid => e
    Rails.logger.error "Failed to assign evaluator: #{e.message}"
    errors.add(:base, e.message)
    false
  end

  # Returns the most recent evaluation for this application
  # @return [Evaluation, nil] The latest evaluation or nil if none exists
  def latest_evaluation
    evaluations.order(created_at: :desc).first
  end

  # Returns the date of the most recently completed evaluation
  # @return [DateTime, nil] The date of the last completed evaluation or nil if none exists
  def last_evaluation_completed_at
    evaluations.where(status: :completed).order(evaluation_date: :desc).limit(1).pick(:evaluation_date)
  end

  # Returns all evaluations for this application in descending order of creation
  # @return [ActiveRecord::Relation<Evaluation>] All evaluations
  def all_evaluations
    evaluations.order(created_at: :desc)
  end

  private

  def reusable_evaluation_for_assignment
    evaluations.where(status: REUSABLE_EVALUATION_STATUSES).order(created_at: :desc, id: :desc).first
  end

  def determine_evaluation_type
    user&.evaluations&.exists? ? :renewal : :initial
  end
end
