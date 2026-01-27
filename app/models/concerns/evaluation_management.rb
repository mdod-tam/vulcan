# frozen_string_literal: true

# Handles operations related to evaluation management
# This includes evaluator assignment and evaluation scheduling
module EvaluationManagement
  extend ActiveSupport::Concern

  # Assigns an evaluator to this application
  # @param evaluator [Evaluator] The evaluator to assign
  # @return [Boolean] True if the evaluator was assigned successfully
  def assign_evaluator!(evaluator)
    with_lock do
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

  def determine_evaluation_type
    user&.evaluations&.exists? ? :follow_up : :initial
  end
end
