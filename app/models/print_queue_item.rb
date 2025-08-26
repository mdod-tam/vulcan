# frozen_string_literal: true

# == Schema Information
#
# Table name: print_queue_items
#
#  id              :bigint           not null, primary key
#  letter_type     :integer          not null
#  status          :integer          default("pending"), not null
#  constituent_id  :bigint           not null
#  application_id  :bigint
#  admin_id        :bigint
#  printed_at      :datetime
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#
class PrintQueueItem < ApplicationRecord
  belongs_to :constituent, class_name: 'User'
  belongs_to :application, optional: true
  belongs_to :admin, -> { where(type: 'Users::Administrator') }, optional: true, class_name: 'User'

  has_one_attached :pdf_letter

  # Define enums with explicit name parameter
  enum :letter_type, {
    account_created: 0,
    income_proof_rejected: 1,
    residency_proof_rejected: 2,
    income_threshold_exceeded: 3,
    application_approved: 4,
    registration_confirmation: 5,
    other_notification: 6,
    proof_approved: 7,
    max_rejections_reached: 8,
    proof_submission_error: 9,
    evaluation_submitted: 10,
    medical_certification_form: 11
  }

  enum :status, { pending: 0, printed: 1, canceled: 2 }

  validates :letter_type, presence: true
  validates :pdf_letter, presence: true, on: :create

  scope :pending, -> { where(status: :pending) }
  scope :recent, -> { order(created_at: :desc) }

  def mark_as_printed(admin)
    update(status: :printed, admin_id: admin.id, printed_at: Time.current)
  end
end
