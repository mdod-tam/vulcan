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
    with_lock do
      errors.clear
      reject_training_assignment!('Select an active trainer.') unless eligible_trainer_for_assignment?(trainer)
      reject_training_assignment!(:training_service_window) unless service_window_active?
      reject_training_assignment!(:training_session_quota_exhausted) if training_session_quota_exhausted?
      reject_training_assignment!(:training_session_active) if active_training_session_present?
      reject_training_assignment!('Remove the current trainer before assigning another trainer.') if assigned_trainer_id.present?

      update!(assigned_trainer: trainer)
      training_session = training_sessions.create!(trainer: trainer, status: :requested)
      AuditEventService.log(
        action: 'trainer_assigned', actor: actor, auditable: self,
        metadata: { application_id: id, trainer_id: trainer.id, training_session_id: training_session.id }
      )
      @training_notification_outcomes << TrainingSessionNotifier.new(
        training_session, actor: actor, action: 'trainer_assigned'
      ).deliver_after_commit
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

  def eligible_trainer_for_assignment?(trainer)
    trainer&.persisted? && trainer.assignable_trainer? && trainer.public_login_active?
  end

  def reject_training_assignment!(message)
    errors.add(:base, message)
    raise ActiveRecord::RecordInvalid, self
  end
end
