# frozen_string_literal: true

class TrainingSession < ApplicationRecord
  has_many :email_delivery_attempts, as: :origin, dependent: :nullify
  include StatusManagement

  # `rescheduled` is a legacy display status. Current reschedules keep sessions scheduled.
  OPEN_STATUSES = %i[requested scheduled confirmed].freeze
  HISTORICAL_STATUSES = %i[completed cancelled no_show].freeze

  belongs_to :application
  belongs_to :trainer, class_name: 'User'
  has_one :constituent, through: :application, source: :user
  belongs_to :product_trained_on, class_name: 'Product', optional: true

  enum :cancellation_initiator, {
    constituent: 0,
    trainer: 1,
    admin: 2,
    program: 3
  }, prefix: true

  # The canonical open-session set includes requested rows. StatusManagement.active excludes them.
  scope :assigned_or_scheduled, -> { where(status: OPEN_STATUSES) }
  scope :latest_per_application, lambda {
    select('DISTINCT ON (training_sessions.application_id) training_sessions.*')
      .order('training_sessions.application_id, training_sessions.created_at DESC, training_sessions.id DESC')
  }

  def self.latest_per_application_records
    unscoped.from("(#{unscoped.latest_per_application.to_sql}) AS training_sessions")
  end

  def self.latest_followup_per_application(statuses = %i[no_show cancelled])
    latest_per_application_records.where(status: statuses)
  end

  def self.ordered_followup_per_application(statuses = %i[no_show cancelled])
    latest_followup_per_application(statuses)
      .includes(application: :user)
      .order(updated_at: :desc)
  end

  validates :scheduled_for, presence: true, if: -> { status_scheduled? || status_confirmed? || will_be_scheduled? }
  validates :reschedule_reason, presence: true, if: :rescheduling?
  validate :trainer_must_be_trainer_type
  validate :scheduled_time_must_be_future
  validate :recorded_outcome_cannot_change
  validate :training_session_capacity_available, if: :entering_open_status?

  validates :cancellation_reason, presence: true, if: :status_cancelled?
  validates :no_show_notes, presence: true, if: :status_no_show?
  validates :constituent_summary, :summary_locale, :completed_at, :report_submitted_at, :product_trained_on, presence: true, if: :status_completed?
  validates :summary_locale, inclusion: { in: ->(_session) { I18n.available_locales.map(&:to_s) } }, if: :status_completed?
  validate :actual_completion_not_in_future, if: :status_completed?
  validate :one_open_appointment, if: :entering_open_status?
  validates :duration_hours, presence: true, numericality: { greater_than: 0 }, if: :status_completed?

  before_save :set_cancelled_at, if: :status_changed_to_cancelled?
  before_save :ensure_status_schedule_consistency

  def status_changed_to_cancelled?
    status_cancelled? && status_changed?
  end

  def set_cancelled_at
    self.cancelled_at = Time.current if status_cancelled? && cancelled_at.nil?
  end

  def rescheduling?
    persisted? && %w[scheduled confirmed].include?(status_was) &&
      (status_scheduled? || status_confirmed?) && scheduled_for_changed?
  end

  def will_be_scheduled?
    return false unless status_changed?

    status_was != 'scheduled' && status == 'scheduled'
  end

  def previous_completed_sessions
    return self.class.none unless application && created_at

    application.training_sessions
               .completed_sessions
               .where.not(id: id)
               .where('training_sessions.created_at < :time OR (training_sessions.created_at = :time AND training_sessions.id < :id)', time: created_at, id: id)
               .includes(:trainer, :product_trained_on)
               .order(completed_at: :desc, created_at: :desc, id: :desc)
  end

  def follow_up_reason
    cancellation_reason.presence || no_show_notes.presence
  end

  def follow_up_reference_time
    scheduled_for || cancelled_at || updated_at
  end

  def appointment_number
    return unless persisted?

    application.training_sessions
               .where('created_at < :time OR (created_at = :time AND id <= :id)', time: created_at, id: id)
               .count
  end

  def with_current_trainer_lock(actor)
    application.with_lock do
      with_lock do
        errors.clear
        raise ArgumentError, I18n.t('training_rules.current_trainer_change') unless application.current_trainer?(actor) && trainer_id == actor&.id

        yield
      end
    end
  end

  def open_status?
    OPEN_STATUSES.include?(status&.to_sym)
  end

  private

  def entering_open_status?
    return false unless application_id
    return false unless OPEN_STATUSES.include?(status&.to_sym)
    return false if reopening_historical_session?

    new_record? || will_save_change_to_status?
  end

  def training_session_capacity_available
    reserved_count = application.training_sessions
                                .where(status: OPEN_STATUSES + [:completed])
                                .where.not(id: id)
                                .count
    return if reserved_count < application.max_training_sessions

    errors.add(:base, :training_session_quota_exhausted)
  end

  def reopening_historical_session?
    return false unless persisted? && will_save_change_to_status?
    return false unless OPEN_STATUSES.include?(status&.to_sym)

    HISTORICAL_STATUSES.include?(status_was&.to_sym)
  end

  def recorded_outcome_cannot_change
    return unless persisted? && will_save_change_to_status? && HISTORICAL_STATUSES.include?(status_was&.to_sym)

    if OPEN_STATUSES.include?(status&.to_sym)
      errors.add(:base, :historical_session_reopen)
    else
      errors.add(:base, I18n.t('training_rules.outcome_recorded'))
    end
  end

  def trainer_must_be_trainer_type
    return unless trainer

    return if trainer.assignable_trainer?

    errors.add(:trainer, 'must be a trainer')
  end

  def scheduled_time_must_be_future
    return unless status_scheduled? || status_confirmed?
    return unless scheduled_for_changed? || new_record?
    return unless scheduled_for.present? && scheduled_for <= Time.current

    errors.add(:scheduled_for, 'must be in the future')
  end

  def actual_completion_not_in_future
    errors.add(:completed_at, I18n.t('training_rules.future_actual_completion')) if completed_at&.future?
  end

  def one_open_appointment
    return unless application.training_sessions.assigned_or_scheduled.where.not(id: id).exists?

    errors.add(:base, I18n.t('training_rules.close_open_first'))
  end

  def ensure_status_schedule_consistency
    self.status = :scheduled if scheduled_for_changed? && scheduled_for.present? && status_requested?

    return unless scheduled_for_changed? && scheduled_for.blank? && (status_scheduled? || status_confirmed?)

    errors.add(:scheduled_for, "cannot be removed while status is #{status}")
    throw(:abort)
  end
end
