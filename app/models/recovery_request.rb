# frozen_string_literal: true

class RecoveryRequest < ApplicationRecord
  VERIFICATION_METHODS = { 'staff_assisted_non_sms' => 'Staff-assisted identity check (no SMS)' }.freeze
  VERIFICATION_REFERENCE_LIMIT = 200

  belongs_to :user
  belongs_to :resolved_by, class_name: 'User', optional: true
  has_one :approval_notification, -> { where(action: 'security_key_recovery_approved') },
          as: :notifiable, class_name: 'Notification', inverse_of: :notifiable, dependent: :restrict_with_exception

  attr_accessor :identity_check_completed

  scope :pending, -> { where(status: 'pending') }

  validates :status, presence: true
  validates :ip_address, presence: true
  validates :user_agent, presence: true
  validates :verification_method, inclusion: { in: VERIFICATION_METHODS.keys }, on: :approval
  validates :verification_result, inclusion: { in: ['verified'] }, on: :approval
  validates :verification_reference, presence: true, length: { maximum: VERIFICATION_REFERENCE_LIMIT }, on: :approval
  validates :identity_check_completed, acceptance: { allow_nil: false }, on: :approval

  # Default values
  after_initialize :set_default_values, if: :new_record?

  def pending?
    status.to_s == 'pending'
  end

  def approved?
    status == 'approved'
  end

  private

  def set_default_values
    self.status ||= 'pending'
  end
end
