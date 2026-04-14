# frozen_string_literal: true

class TrainingSession < ApplicationRecord
  include StatusManagement
  include NotificationDelivery

  # Associations
  belongs_to :application
  belongs_to :trainer, class_name: 'User'
  has_one :constituent, through: :application, source: :user
  belongs_to :product_trained_on, class_name: 'Product', optional: true # Added association

  scope :assigned_or_scheduled, -> { where(status: %i[requested scheduled confirmed]) }

  # Validations
  validates :scheduled_for, presence: true, if: -> { status_scheduled? || status_confirmed? || will_be_scheduled? }
  validates :reschedule_reason, presence: true, if: :rescheduling?
  validate :trainer_must_be_trainer_type
  validate :scheduled_time_must_be_future, on: :create

  # Conditional Validations based on status
  validates :cancellation_reason, presence: true, if: :status_cancelled?
  validates :no_show_notes, presence: true, if: :status_no_show?
  validates :notes, presence: true, if: :status_completed?

  # Callbacks
  before_save :set_completed_at, if: :status_changed_to_completed?
  # Add a callback to set cancelled_at if status changes to cancelled
  before_save :set_cancelled_at, if: :status_changed_to_cancelled?
  before_save :ensure_status_schedule_consistency
  after_save :deliver_notifications, if: :saved_change_to_status?

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

  private

  def trainer_must_be_trainer_type
    return if trainer&.type == 'Users::Trainer'

    errors.add(:trainer, 'must be a trainer')
  end

  def scheduled_time_must_be_future
    # Only apply this validation if the status being set requires a future date
    return unless status_scheduled? || status_confirmed?
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
    status_changed? || saved_change_to_scheduled_for? || saved_change_to_completed_at?
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
