# frozen_string_literal: true

class RecoveryRequest < ApplicationRecord
  belongs_to :user
  belongs_to :resolved_by, class_name: 'User', optional: true

  scope :pending, -> { where(status: 'pending') }

  validates :status, presence: true
  validates :ip_address, presence: true
  validates :user_agent, presence: true

  # Default values
  after_initialize :set_default_values, if: :new_record?

  def pending?
    status.to_s == 'pending'
  end

  private

  def set_default_values
    self.status ||= 'pending'
  end
end
