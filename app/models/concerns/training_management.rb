# frozen_string_literal: true

module TrainingManagement
  extend ActiveSupport::Concern

  included do
    belongs_to :assigned_trainer, class_name: 'User', optional: true
    attr_reader :training_notification_outcomes
  end

  delegate :max_training_sessions, to: :Policy

  def completed_training_sessions_count
    training_sessions.completed_sessions.count
  end

  def open_training_sessions_count
    training_sessions.assigned_or_scheduled.count
  end

  def reserved_training_sessions_count
    completed_training_sessions_count + open_training_sessions_count
  end

  def remaining_training_sessions
    [max_training_sessions - reserved_training_sessions_count, 0].max
  end

  def training_session_quota_exhausted?
    reserved_training_sessions_count >= max_training_sessions
  end

  def current_trainer?(actor)
    actor.present? && assigned_trainer_id == actor.id
  end

  def latest_training_session
    training_sessions.order(created_at: :desc, id: :desc).first
  end

  def latest_training_follow_up_session
    latest_session = latest_training_session
    return unless latest_session&.needs_followup?
    return if new_training_work_eligibility_error(actor: assigned_trainer, source: latest_session)

    latest_session
  end

  def additional_training_session_eligible?(session, actor:)
    session.status_completed? && new_training_work_eligibility_error(actor: actor, source: session).nil?
  end

  # Writers call this after acquiring the application and source-session locks.
  def new_training_work_eligibility_error(actor:, source:)
    return I18n.t('training_rules.current_trainer_create') unless current_trainer?(actor) && source.trainer_id == actor.id
    return I18n.t('training_rules.new_work_service_window') unless service_window_active?
    return I18n.t('training_rules.quota_reached') if training_session_quota_exhausted?
    return I18n.t('training_rules.close_open_first') if active_training_session_present?
    return I18n.t('training_rules.latest_source') unless latest_training_session&.id == source.id

    nil
  end

  def assign_trainer!(trainer, actor: Current.user)
    @training_notification_outcomes = []
    transaction do
      trainer, actor = lock_assignment_participants(trainer, actor)
      with_lock do
        errors.clear
        reject_training_assignment!('Only an administrator can assign a trainer.') unless assignment_actor_eligible?(actor)
        reject_training_assignment!('Select an active trainer.') unless trainer&.assignable_trainer?
        reject_training_assignment!(:training_service_window) unless service_window_active?
        reject_training_assignment!(:training_session_quota_exhausted) if training_session_quota_exhausted?
        reject_training_assignment!(:training_session_active) if active_training_session_present?
        reject_training_assignment!('Remove the current trainer before assigning another trainer.') if assigned_trainer_id.present?

        operation_id = SecureRandom.uuid
        update!(assigned_trainer: trainer)
        training_session = training_sessions.create!(trainer: trainer, status: :requested, assignment_operation_id: operation_id)
        AuditEventService.log(
          action: 'trainer_assigned', actor: actor, auditable: self,
          metadata: { operation_id: operation_id, application_id: id, trainer_id: trainer.id, training_session_id: training_session.id }
        )
        @training_notification_outcomes << TrainingSessionNotifier.new(
          training_session, actor: actor, action: 'trainer_assigned'
        ).deliver_after_commit
      end
    end

    Application.expire_training_request_metrics_cache!
    true
  rescue ActiveRecord::RecordInvalid => e
    errors.add(:base, e.record.errors.full_messages.to_sentence) unless e.record.equal?(self)
    false
  end

  # Rows still owed to the constituent: neither completed nor cancelled, so no-show and rescheduled rows count.
  def open_training_assignments
    training_sessions.open_assigned.order(:id)
  end

  # Identifies the coverage an administrator reviewed: the coverage holder and who holds each open row.
  def training_assignment_version(sessions = open_training_assignments)
    Digest::SHA256.hexdigest([assigned_trainer_id, sessions.map { |session| [session.id, session.trainer_id] }].to_json)
  end

  # Transfers every open training row and the coverage to another trainer, keeping schedules, outcomes and notes.
  # `expected_version` is the coverage the administrator reviewed; changed coverage is refused, not overwritten.
  def reassign_trainer!(trainer, actor:, expected_version:)
    @training_notification_outcomes = []
    transaction do
      trainer, actor, locked_ids = lock_assignment_participants(trainer, actor, [assigned_trainer_id, *open_training_assignments.pluck(:trainer_id)])
      with_lock do
        errors.clear
        sessions = open_training_assignments.lock.to_a
        verify_trainer_reassignment!(trainer, actor, sessions, locked_ids, expected_version)
        next if assigned_trainer_id == trainer.id && sessions.all? { |session| session.trainer_id == trainer.id }

        current_ids = training_coverage_ids(sessions)
        operation_id = SecureRandom.uuid
        update!(assigned_trainer: trainer)
        sessions.each { |session| session.update!(trainer: trainer, assignment_operation_id: operation_id) }
        AuditEventService.log(
          action: 'trainer_reassigned', actor: actor, auditable: self,
          metadata: { operation_id: operation_id, application_id: id, trainer_id: trainer.id, previous_trainer_ids: current_ids - [trainer.id],
                      training_session_ids: sessions.map(&:id) }
        )
        %w[trainer_reassigned training_trainer_changed].each do |action|
          @training_notification_outcomes << TrainingSessionNotifier.new(sessions.last, actor: actor, action: action).deliver_after_commit
        end
      end
    end

    Application.expire_training_request_metrics_cache!
    true
  rescue ActiveRecord::RecordInvalid => e
    errors.add(:base, e.record.errors.full_messages.to_sentence) unless e.record.equal?(self)
    false
  end

  def unassign_trainer!(actor:, reason: nil)
    @training_notification_outcomes = []
    with_lock do
      errors.clear
      reject_training_assignment!('Only an administrator can remove trainer coverage.') unless actor&.admin?
      reject_training_assignment!(:training_session_not_active) if assigned_trainer_id.blank?

      trainer_id = assigned_trainer_id
      open_sessions = training_sessions.assigned_or_scheduled.order(:id).lock.to_a
      open_sessions.each do |training_session|
        training_session.update!(
          status: :cancelled, cancelled_at: Time.current, cancellation_initiator: :admin,
          cancellation_reason: reason.presence || 'Trainer assignment removed by administrator.'
        )
        AuditEventService.log(
          action: 'training_cancelled', actor: actor, auditable: training_session,
          metadata: { application_id: id, training_session_id: training_session.id, cancellation_initiator: 'admin' }
        )
        @training_notification_outcomes << TrainingSessionNotifier.new(
          training_session, actor: actor, action: 'training_cancelled'
        ).deliver_after_commit
      end
      update!(assigned_trainer: nil)
      AuditEventService.log(
        action: 'trainer_unassigned', actor: actor, auditable: self,
        metadata: { application_id: id, trainer_id: trainer_id, training_session_ids: open_sessions.map(&:id) }
      )
    end

    Application.expire_training_request_metrics_cache!
    true
  rescue ActiveRecord::RecordInvalid => e
    errors.add(:base, e.record.errors.full_messages.to_sentence) unless e.record.equal?(self)
    false
  end

  private

  def reject_training_assignment!(message)
    errors.add(:base, message)
    raise ActiveRecord::RecordInvalid, self
  end

  def training_coverage_ids(sessions)
    [assigned_trainer_id, *sessions.map(&:trainer_id)].compact.uniq
  end

  # Rejects a reassignment whose actor, trainer or reviewed coverage no longer holds.
  def verify_trainer_reassignment!(trainer, actor, sessions, locked_ids, expected_version)
    reject_training_assignment!('Only an administrator can reassign a trainer.') unless assignment_actor_eligible?(actor)
    reject_training_assignment!(:training_service_window) unless service_window_active?
    reject_training_assignment!('Select an active trainer.') unless trainer&.assignable_trainer?
    reject_training_assignment!('There is no open training to transfer.') if sessions.empty?

    stale = (training_coverage_ids(sessions) - locked_ids).any? || training_assignment_version(sessions) != expected_version
    reject_training_assignment!('Training assignments changed. Review the current assignment and try again.') if stale
  end
end
