# frozen_string_literal: true

module Applications
  # Assigns, transfers and removes an application's trainer coverage with its audit events and notices.
  # The result's data[:notification_outcomes] lists the notices queued for delivery after commit.
  class TrainerAssignment < PractitionerAssignment
    def self.assign(application, trainer, actor:)
      new(application, actor: actor).assign(trainer)
    end

    def self.reassign(application, trainer, actor:, expected_version:)
      new(application, actor: actor).reassign(trainer, expected_version: expected_version)
    end

    def self.unassign(application, actor:, reason: nil)
      new(application, actor: actor).unassign(reason: reason)
    end

    def assign(trainer)
      in_transaction do
        trainer, locked_actor = lock_participants(trainer)
        application.with_lock do
          reject!('Only an administrator can assign a trainer.') unless actor_eligible?(locked_actor)
          reject!('Select an active trainer.') unless trainer&.assignable_trainer?
          reject!(:training_service_window) unless application.service_window_active?
          reject!(:training_session_quota_exhausted) if application.training_session_quota_exhausted?
          reject!(:training_session_active) if application.active_training_session_present?
          reject!('Remove the current trainer before assigning another trainer.') if application.assigned_trainer_id.present?

          operation_id = SecureRandom.uuid
          application.update!(assigned_trainer: trainer)
          training_session = application.training_sessions.create!(trainer: trainer, status: :requested, assignment_operation_id: operation_id)
          AuditEventService.log(
            action: 'trainer_assigned', actor: locked_actor, auditable: application,
            metadata: { operation_id: operation_id, application_id: application.id, trainer_id: trainer.id, training_session_id: training_session.id }
          )
          notify(training_session, 'trainer_assigned', locked_actor)
        end
      end
    end

    # Transfers every open training row and the coverage to another trainer, keeping schedules, outcomes and notes.
    # A coverage holder who can no longer take work is transferred even when no row is open. `expected_version` is
    # the coverage the administrator reviewed; changed coverage is refused, not overwritten.
    def reassign(trainer, expected_version:)
      in_transaction do
        trainer, locked_actor, locked_ids = lock_participants(
          trainer, [application.assigned_trainer_id, *application.open_training_assignments.pluck(:trainer_id)]
        )
        application.with_lock do
          sessions = application.open_training_assignments.lock.to_a
          verify_reassignment!(trainer, locked_actor, sessions, locked_ids, expected_version)
          next if application.assigned_trainer_id == trainer.id && sessions.all? { |session| session.trainer_id == trainer.id }

          current_ids = coverage_ids(sessions)
          operation_id = SecureRandom.uuid
          application.update!(assigned_trainer: trainer)
          sessions.each { |session| session.update!(trainer: trainer, assignment_operation_id: operation_id) }
          AuditEventService.log(
            action: 'trainer_reassigned', actor: locked_actor, auditable: application,
            metadata: { operation_id: operation_id, application_id: application.id, trainer_id: trainer.id,
                        previous_trainer_ids: current_ids - [trainer.id], training_session_ids: sessions.map(&:id) }
          )
          # Without an open row there is no appointment to announce; a pending request shows on the new trainer's dashboard.
          %w[trainer_reassigned training_trainer_changed].each { |action| notify(sessions.last, action, locked_actor) } if sessions.any?
        end
      end
    end

    def unassign(reason: nil)
      in_transaction do
        _assignee, locked_actor = lock_participants(nil)
        application.with_lock do
          reject!('Only an administrator can remove trainer coverage.') unless actor_eligible?(locked_actor)
          reject!(:training_session_not_active) if application.assigned_trainer_id.blank?

          trainer_id = application.assigned_trainer_id
          operation_id = SecureRandom.uuid
          open_sessions = application.training_sessions.assigned_or_scheduled.order(:id).lock.to_a
          open_sessions.each { |training_session| cancel_session(training_session, locked_actor, operation_id, reason) }
          application.update!(assigned_trainer: nil)
          AuditEventService.log(
            action: 'trainer_unassigned', actor: locked_actor, auditable: application,
            metadata: { operation_id: operation_id, application_id: application.id, trainer_id: trainer_id,
                        training_session_ids: open_sessions.map(&:id) }
          )
        end
      end
    end

    private

    def in_transaction
      result = super
      Reports::AdminDashboardMetrics.expire! if result.success?
      result
    end

    def notify(training_session, action, locked_actor)
      @notification_outcomes << TrainingSessionNotifier.new(training_session, actor: locked_actor, action: action).deliver_after_commit
    end

    # A new operation id supersedes any transfer notice still queued for the row.
    def cancel_session(training_session, locked_actor, operation_id, reason)
      training_session.update!(
        status: :cancelled, cancelled_at: Time.current, cancellation_initiator: :admin, assignment_operation_id: operation_id,
        cancellation_reason: reason.presence || 'Trainer assignment removed by administrator.'
      )
      AuditEventService.log(
        action: 'training_cancelled', actor: locked_actor, auditable: training_session,
        metadata: { application_id: application.id, training_session_id: training_session.id, cancellation_initiator: 'admin' }
      )
      notify(training_session, 'training_cancelled', locked_actor)
    end

    def coverage_ids(sessions)
      [application.assigned_trainer_id, *sessions.map(&:trainer_id)].compact.uniq
    end

    # Rejects a reassignment whose actor, trainer or reviewed coverage no longer holds.
    def verify_reassignment!(trainer, locked_actor, sessions, locked_ids, expected_version)
      reject!('Only an administrator can reassign a trainer.') unless actor_eligible?(locked_actor)
      reject!(:training_service_window) unless application.service_window_active?
      reject!('Select an active trainer.') unless trainer&.assignable_trainer?
      reject!('There is no open training to transfer.') if sessions.empty? && !application.covering_trainer_unavailable?

      stale = (coverage_ids(sessions) - locked_ids).any? || application.training_assignment_version(sessions) != expected_version
      reject!('Training assignments changed. Review the current assignment and try again.') if stale
    end
  end
end
