# frozen_string_literal: true

module Applications
  # Assigns an evaluator to an application, or transfers the open evaluation to another evaluator, with its audit
  # events and the assignment notice.
  class EvaluatorAssignment < PractitionerAssignment
    REUSABLE_EVALUATION_STATUSES = %i[requested cancelled no_show rescheduled].freeze

    def self.assign(application, evaluator, actor:)
      new(application, actor: actor).assign(evaluator)
    end

    def self.reassign(application, evaluator, actor:)
      new(application, actor: actor).reassign(evaluator)
    end

    def assign(evaluator)
      in_transaction do
        evaluator, locked_actor = lock_participants(evaluator)
        application.with_lock do
          reject!('Only an administrator can assign an evaluator.') unless actor_eligible?(locked_actor)
          reject!(:evaluation_service_window) unless application.service_window_active?
          reject!('Select an active evaluator.') unless evaluator&.assignable_evaluator?
          reject!(:evaluation_assignment_closed) if application.evaluations.exists?(status: :completed)

          operation_id = SecureRandom.uuid
          existing = reusable_evaluation
          evaluation = existing ? reset_evaluation(existing, evaluator, operation_id) : create_evaluation(evaluator, operation_id)

          AuditEventService.log(
            actor: locked_actor,
            action: 'evaluator_assigned',
            auditable: application,
            metadata: {
              operation_id: operation_id,
              application_id: application.id,
              evaluator_id: evaluator.id,
              evaluator_name: evaluator.full_name,
              timestamp: Time.current.iso8601
            }
          )

          deliver_notice(evaluation, operation_id)
        end
      end
    end

    # Transfers the open evaluation without resetting appointment or outcome history.
    def reassign(evaluator)
      in_transaction do
        evaluator, locked_actor, locked_ids = lock_participants(evaluator, [application.open_evaluation&.evaluator_id])
        application.with_lock do
          reject!(:evaluation_service_window) unless actor_eligible?(locked_actor) && application.service_window_active?
          reject!('Select an active evaluator.') unless evaluator&.assignable_evaluator?

          evaluation = application.open_evaluation
          reject!(:evaluation_assignment_closed) if evaluation.nil?
          reject!('The evaluator changed. Review the current assignment and try again.') unless locked_ids.include?(evaluation.evaluator_id)

          evaluation.with_lock do
            transfer(evaluation, evaluator, locked_actor) unless evaluation.evaluator_id == evaluator.id
          end
        end
      end
    end

    private

    def reusable_evaluation
      application.evaluations.where(status: REUSABLE_EVALUATION_STATUSES).order(created_at: :desc, id: :desc).first
    end

    # Reuses the row for lifecycle state only; narrative notes stay because they may document constituent interactions.
    def reset_evaluation(evaluation, evaluator, operation_id)
      evaluation.update!(
        evaluator: evaluator,
        constituent: application.user,
        application: application,
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
      evaluation
    end

    def create_evaluation(evaluator, operation_id)
      reject!(:evaluation_assignment_closed) if application.evaluations.exists?

      application.evaluations.create!(
        evaluator: evaluator,
        constituent: application.user,
        application: application,
        evaluation_type: evaluation_type,
        evaluation_date: nil, # Will be set when scheduling
        needs: '',
        location: '',
        assignment_operation_id: operation_id
      )
    end

    def transfer(evaluation, evaluator, locked_actor)
      previous_evaluator_id = evaluation.evaluator_id
      operation_id = SecureRandom.uuid
      evaluation.update!(evaluator: evaluator, assignment_operation_id: operation_id)
      AuditEventService.log(
        actor: locked_actor,
        action: 'evaluator_reassigned',
        auditable: evaluation,
        metadata: { operation_id: operation_id, application_id: application.id, evaluation_id: evaluation.id,
                    previous_evaluator_id: previous_evaluator_id, evaluator_id: evaluator.id }
      )
      deliver_notice(evaluation, operation_id)
    end

    def evaluation_type
      application.user&.evaluations&.exists? ? :renewal : :initial
    end

    def deliver_notice(evaluation, operation_id)
      EvaluatorMailer.with(evaluation: evaluation, recipient: evaluation.evaluator, operation_id: operation_id).new_evaluation_assigned.deliver_later
    end
  end
end
