# frozen_string_literal: true

module StatusManagement
  extend ActiveSupport::Concern

  included do
    # `rescheduled` remains for legacy/display compatibility. Current training
    # reschedules keep the row in `scheduled` status and log a reschedule event.
    enum :status, {
      requested: 0,
      scheduled: 1,
      confirmed: 2,
      completed: 3,
      cancelled: 4,
      rescheduled: 5,
      no_show: 6
    }, prefix: true, validate: true

    scope :active, -> { where(status: %i[scheduled confirmed]) }
    scope :pending, -> { where(status: %i[scheduled confirmed]) }
    scope :completed_sessions, -> { where(status: :completed) }
    scope :needing_followup, -> { where(status: %i[no_show cancelled]) }
    scope :requested_sessions, -> { where(status: :requested) }
  end

  def active?
    status_scheduled? || status_confirmed?
  end

  def complete?
    status_completed?
  end

  def needs_followup?
    status_no_show? || status_cancelled?
  end

  def can_reschedule?
    can_schedule_followup?
  end

  def can_schedule_followup?
    status_cancelled? || status_no_show?
  end

  def can_reschedule_current_session?
    status_scheduled? || status_confirmed?
  end

  def can_cancel?
    status_scheduled? || status_confirmed?
  end

  def can_complete?
    status_scheduled? || status_confirmed?
  end

  def rescheduling?
    return false unless persisted?

    # Get the date field name for this model
    date_field = self.class.status_management_date_field
    return false unless date_field

    # Only consider it rescheduling if:
    # 1. The date is changing AND
    # 2. We're staying in a scheduled state (not completing or cancelling)
    return true if send("#{date_field}_changed?") && status_scheduled? && !status_changed?

    # Or if we're explicitly changing TO rescheduled status
    return true if status_changed? && status_rescheduled?

    false
  end

  class_methods do
    def status_management_date_field(field_name = nil)
      if field_name
        @status_management_date_field = field_name
      else
        @status_management_date_field
      end
    end
  end
end
