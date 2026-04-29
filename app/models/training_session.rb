# frozen_string_literal: true

class TrainingSession < ApplicationRecord
  include StatusManagement
  include NotificationDelivery

  OPEN_STATUSES = %i[requested scheduled confirmed].freeze
  HISTORICAL_STATUSES = %i[completed cancelled no_show].freeze

  # Associations
  belongs_to :application
  belongs_to :trainer, class_name: 'User'
  has_one :constituent, through: :application, source: :user
  belongs_to :product_trained_on, class_name: 'Product', optional: true # Added association

  attribute :cancellation_initiator, :integer

  enum :cancellation_initiator, {
    constituent: 0,
    trainer: 1,
    admin: 2,
    program: 3
  }, prefix: true

  # Canonical open-session set for training. The shared StatusManagement
  # `active` scope is narrower legacy language and excludes requested rows.
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

  # Validations
  validates :scheduled_for, presence: true, if: -> { status_scheduled? || status_confirmed? || will_be_scheduled? }
  validates :reschedule_reason, presence: true, if: :rescheduling?
  validate :trainer_must_be_trainer_type
  validate :scheduled_time_must_be_future
  validate :historical_session_cannot_reopen, if: :reopening_historical_session?
  validate :at_most_one_open_session_per_application, if: :entering_open_status?

  # Conditional Validations based on status
  validates :cancellation_reason, presence: true, if: :status_cancelled?
  validates :no_show_notes, presence: true, if: :status_no_show?
  validates :notes, presence: true, if: :status_completed?

  # Callbacks
  before_save :set_completed_at, if: :status_changed_to_completed?
  # Add a callback to set cancelled_at if status changes to cancelled
  before_save :set_cancelled_at, if: :status_changed_to_cancelled?
  before_save :ensure_status_schedule_consistency
  after_update_commit :deliver_notifications, if: :should_deliver_notifications?

  # Add a helper method for cancellation status change
  def status_changed_to_cancelled?
    status_cancelled? && status_changed?
  end

  # Add a callback method to set cancelled_at
  def set_cancelled_at
    self.cancelled_at = Time.current if status_cancelled? && cancelled_at.nil?
  end

  def rescheduling?
    # A reschedule only occurs if:
    # 1. The record already exists (is persisted).
    # 2. The status *was* already 'scheduled'.
    # 3. The scheduled_for date is changing.
    persisted? && status_was == 'scheduled' && scheduled_for_changed?
  end

  # Detects if this record is being changed to 'scheduled' status
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

  private

  def entering_open_status?
    return false unless application_id
    return false unless OPEN_STATUSES.include?(status&.to_sym)
    return false if reopening_historical_session?

    new_record? || will_save_change_to_status?
  end

  def at_most_one_open_session_per_application
    return unless application.training_sessions
                             .where(status: OPEN_STATUSES)
                             .where.not(id: id)
                             .exists?

    errors.add(:base, :duplicate_open_session)
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
    # Only apply this validation if the status being set requires a future date
    return unless status_scheduled? || status_confirmed?
    # Only validate if the scheduled time is being set or changed
    return unless scheduled_for_changed? || new_record?
    # Now check the date
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
    # If setting a schedule date but still in requested status, update status
    self.status = :scheduled if scheduled_for_changed? && scheduled_for.present? && status_requested?

    # If removing a schedule date but still in scheduled/confirmed status, prevent it
    return unless scheduled_for_changed? && scheduled_for.blank? && (status_scheduled? || status_confirmed?)

    errors.add(:scheduled_for, "cannot be removed while status is #{status}")
    throw(:abort)
  end
end
