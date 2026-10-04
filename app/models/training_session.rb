# frozen_string_literal: true

class TrainingSession < ApplicationRecord
  has_many :email_delivery_attempts, as: :origin, dependent: :nullify
  include StatusManagement
  include NotificationDelivery

  # `rescheduled` is a legacy display status. Current reschedules keep sessions scheduled.
  OPEN_STATUSES = %i[requested scheduled confirmed].freeze
  HISTORICAL_STATUSES = %i[completed cancelled no_show].freeze

  belongs_to :application
  belongs_to :trainer, class_name: 'User'
  has_one :constituent, through: :application, source: :user
  belongs_to :product_trained_on, class_name: 'Product', optional: true

  attribute :cancellation_initiator, :integer

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
  validate :historical_session_cannot_reopen, if: :reopening_historical_session?
  validate :training_session_capacity_available, if: :entering_open_status?

  validates :cancellation_reason, presence: true, if: :status_cancelled?
  validates :no_show_notes, presence: true, if: :status_no_show?
  validates :notes, presence: true, if: :status_completed?
  validates :duration_hours, presence: true, numericality: { greater_than: 0 }, if: :status_completed?

  before_save :set_completed_at, if: :status_changed_to_completed?
  before_save :set_cancelled_at, if: :status_changed_to_cancelled?
  before_save :ensure_status_schedule_consistency
  after_update_commit :deliver_notifications, if: :should_deliver_notifications?

  def status_changed_to_cancelled?
    status_cancelled? && status_changed?
  end

  def set_cancelled_at
    self.cancelled_at = Time.current if status_cancelled? && cancelled_at.nil?
  end

  def rescheduling?
    persisted? && status_was == 'scheduled' && scheduled_for_changed?
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
               .where(training_sessions: { created_at: ...created_at })
               .includes(:trainer, :product_trained_on)
               .order(completed_at: :desc, created_at: :desc)
  end

  def follow_up_reason
    cancellation_reason.presence || no_show_notes.presence
  end

  def follow_up_reference_time
    scheduled_for || cancelled_at || updated_at
  end

  def self.cancellation_initiator_column?
    connection.schema_cache.columns_hash(table_name).key?('cancellation_initiator')
  rescue ActiveRecord::ActiveRecordError
    false
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

  def historical_session_cannot_reopen
    errors.add(:base, :historical_session_reopen)
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

  def cannot_complete_without_notes
    return if notes.present?

    errors.add(:notes, 'must be provided when completing training')
  end

  def set_completed_at
    self.completed_at = Time.current if status_completed? && completed_at.nil?
  end

  def status_changed_to_completed?
    status_completed? && status_changed?
  end

  def should_deliver_notifications?
    return false if Rails.env.test? && !Thread.current[:force_notifications]

    saved_change_to_status? || saved_change_to_scheduled_for? || saved_change_to_completed_at?
  end

  def ensure_status_schedule_consistency
    self.status = :scheduled if scheduled_for_changed? && scheduled_for.present? && status_requested?

    return unless scheduled_for_changed? && scheduled_for.blank? && (status_scheduled? || status_confirmed?)

    errors.add(:scheduled_for, "cannot be removed while status is #{status}")
    throw(:abort)
  end
end
