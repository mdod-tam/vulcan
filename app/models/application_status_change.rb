# frozen_string_literal: true

class ApplicationStatusChange < ApplicationRecord
  belongs_to :application
  belongs_to :user, optional: true

  enum :change_type, {
    medical_certification: 0,
    proof: 1,
    status: 2
  }

  validates :from_status, presence: true
  validates :to_status, presence: true
  validates :changed_at, presence: true

  before_validation :set_changed_at

  # Normalize legacy status names for backward compatibility
  def normalized_from_status
    case from_status
    when 'awaiting_documents' then 'awaiting_dcf'
    when 'needs_information' then 'awaiting_proof'
    else from_status
    end
  end

  def normalized_to_status
    case to_status
    when 'awaiting_documents' then 'awaiting_dcf'
    when 'needs_information' then 'awaiting_proof'
    else to_status
    end
  end

  # Use this in views/helpers instead of direct status access
  def display_from_status
    normalized_from_status.humanize
  end

  def display_to_status
    normalized_to_status.humanize
  end

  private

  def set_changed_at
    self.changed_at ||= Time.current
  end
end
