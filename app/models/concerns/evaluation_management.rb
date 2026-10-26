# frozen_string_literal: true

# Evaluator assignment and evaluation lookups for an application.
module EvaluationManagement
  extend ActiveSupport::Concern

  REUSABLE_EVALUATION_STATUSES = %i[requested cancelled no_show rescheduled].freeze

  # Assigns an evaluator to this application
  # @param evaluator [User] The evaluator to assign
  # @return [Boolean] True if the evaluator was assigned successfully
  def assign_evaluator!(evaluator, actor: Current.user)
    transaction do
      evaluator, actor = lock_assignment_participants(evaluator, actor)
      with_lock do
        errors.clear
        reject_evaluation_assignment!('Only an administrator can assign an evaluator.') unless assignment_actor_eligible?(actor)
        reject_evaluation_assignment!(:evaluation_service_window) unless service_window_active?
        reject_evaluation_assignment!('Select an active evaluator.') unless evaluator&.assignable_evaluator?
        reject_evaluation_assignment!(:evaluation_assignment_closed) if evaluations.exists?(status: :completed)

        evaluation = reusable_evaluation_for_assignment
        operation_id = SecureRandom.uuid

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
            reschedule_reason: nil,
            assignment_operation_id: operation_id
          )
        else
          reject_evaluation_assignment!(:evaluation_assignment_closed) if evaluations.exists?

          evaluation = evaluations.create!(
            evaluator: evaluator,
            constituent: user,
            application: self,
            evaluation_type: determine_evaluation_type,
            evaluation_date: nil, # Will be set when scheduling
            needs: '',
            location: '',
            assignment_operation_id: operation_id
          )
        end

        AuditEventService.log(
          actor: actor,
          action: 'evaluator_assigned',
          auditable: self,
          metadata: {
            operation_id: operation_id,
            application_id: id,
            evaluator_id: evaluator.id,
            evaluator_name: evaluator.full_name,
            timestamp: Time.current.iso8601
          }
        )

        deliver_evaluation_assignment_notice(evaluation, operation_id)
      end
    end
    true
  rescue ActiveRecord::RecordInvalid => e
    errors.add(:base, e.record.errors.full_messages.to_sentence) unless e.record.equal?(self)
    false
  end

  # Transfers the open evaluation without resetting appointment or outcome history.
  def reassign_evaluator!(evaluator, actor:)
    transaction do
      evaluator, actor, locked_ids = lock_assignment_participants(evaluator, actor, [open_evaluation&.evaluator_id])
      with_lock do
        errors.clear
        reject_evaluation_assignment!(:evaluation_service_window) unless assignment_actor_eligible?(actor) && service_window_active?
        reject_evaluation_assignment!('Select an active evaluator.') unless evaluator&.assignable_evaluator?

        evaluation = open_evaluation
        reject_evaluation_assignment!(:evaluation_assignment_closed) if evaluation.nil?
        reject_evaluation_assignment!('The evaluator changed. Review the current assignment and try again.') unless locked_ids.include?(evaluation.evaluator_id)

        evaluation.with_lock do
          unless evaluation.evaluator_id == evaluator.id
            previous_evaluator_id = evaluation.evaluator_id
            operation_id = SecureRandom.uuid
            evaluation.update!(evaluator: evaluator, assignment_operation_id: operation_id)
            AuditEventService.log(
              actor: actor,
              action: 'evaluator_reassigned',
              auditable: evaluation,
              metadata: { operation_id: operation_id, application_id: id, evaluation_id: evaluation.id,
                          previous_evaluator_id: previous_evaluator_id, evaluator_id: evaluator.id }
            )
            deliver_evaluation_assignment_notice(evaluation, operation_id)
          end
        end
      end
    end
    true
  rescue ActiveRecord::RecordInvalid => e
    errors.add(:base, e.record.errors.full_messages.to_sentence) unless e.record.equal?(self)
    false
  end

  # The evaluation still owed to the constituent: neither completed nor cancelled.
  def open_evaluation
    evaluations.open_assigned.order(:id).last
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

  def deliver_evaluation_assignment_notice(evaluation, operation_id)
    EvaluatorMailer.with(evaluation: evaluation, recipient: evaluation.evaluator, operation_id: operation_id).new_evaluation_assigned.deliver_later
  end

  def reject_evaluation_assignment!(message)
    errors.add(:base, message)
    raise ActiveRecord::RecordInvalid, self
  end

  def reusable_evaluation_for_assignment
    evaluations.where(status: REUSABLE_EVALUATION_STATUSES).order(created_at: :desc, id: :desc).first
  end

  def determine_evaluation_type
    user&.evaluations&.exists? ? :renewal : :initial
  end
end
