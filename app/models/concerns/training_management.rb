# frozen_string_literal: true

module TrainingManagement
  extend ActiveSupport::Concern

  included do
    belongs_to :assigned_trainer, class_name: 'User', optional: true
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

  # The covering trainer can no longer take work, so the coverage needs a new holder even when no row is open.
  def covering_trainer_unavailable?
    assigned_trainer.present? && !assigned_trainer.assignable_trainer?
  end

  # Rows still owed to the constituent: neither completed nor cancelled, with a no-show counted until a later
  # session resolves it.
  def open_training_assignments
    training_sessions.open_assigned.order(:id)
  end

  # Identifies the coverage an administrator reviewed: the coverage holder and who holds each open row.
  def training_assignment_version(sessions = open_training_assignments)
    Digest::SHA256.hexdigest([assigned_trainer_id, sessions.map { |session| [session.id, session.trainer_id] }].to_json)
  end
end
