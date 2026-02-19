# frozen_string_literal: true

class ApplicationNote < ApplicationRecord
  # Associations
  belongs_to :application
  belongs_to :admin, -> { where(type: 'Users::Administrator') }, class_name: 'User'
  belongs_to :assigned_to, class_name: 'User', optional: true

  # Validations
  validates :content, presence: true

  # Scopes
  scope :recent_first, -> { order(created_at: :desc) }
  scope :public_notes, -> { where(internal_only: false) }
  scope :internal_notes, -> { where(internal_only: true) }
  scope :assigned, -> { where.not(assigned_to_id: nil) }
  scope :unassigned, -> { where(assigned_to_id: nil) }
  scope :assigned_to, ->(user) { where(assigned_to_id: user.id) }
  scope :incomplete, -> { where(completed_at: nil) }
  scope :completed, -> { where.not(completed_at: nil) }

  # Assignment Methods
  def assign_to!(user)
    with_lock do
      update!(assigned_to: user)

      AuditEventService.log(
        action: 'note_assigned',
        actor: Current.user,
        auditable: application,
        metadata: {
          note_id: id,
          assigned_to_id: user.id,
          assigned_to_name: user.full_name
        }
      )
    end
    true
  rescue StandardError => e
    Rails.logger.error "Failed to assign note: #{e.message}"
    false
  end

  def unassign!
    with_lock do
      update!(assigned_to_id: nil)

      AuditEventService.log(
        action: 'note_unassigned',
        actor: Current.user,
        auditable: application,
        metadata: {
          note_id: id
        }
      )
    end
    true
  rescue StandardError => e
    Rails.logger.error "Failed to unassign note: #{e.message}"
    false
  end

  def mark_as_done!
    with_lock do
      update!(completed_at: Time.current)

      AuditEventService.log(
        action: 'note_completed',
        actor: Current.user,
        auditable: application,
        metadata: {
          note_id: id,
          completed_by_id: Current.user.id,
          completed_by_name: Current.user.full_name
        }
      )
    end
    true
  rescue StandardError => e
    Rails.logger.error "Failed to mark note as done: #{e.message}"
    false
  end

  def mark_as_incomplete!
    with_lock do
      update!(completed_at: nil)

      AuditEventService.log(
        action: 'note_reopened',
        actor: Current.user,
        auditable: application,
        metadata: {
          note_id: id
        }
      )
    end
    true
  rescue StandardError => e
    Rails.logger.error "Failed to reopen note: #{e.message}"
    false
  end
end
