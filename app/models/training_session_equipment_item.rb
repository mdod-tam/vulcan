# frozen_string_literal: true

class TrainingSessionEquipmentItem < ApplicationRecord
  belongs_to :training_session, inverse_of: :training_session_equipment_items
  belongs_to :equipment_item
  validates :equipment_item_id, uniqueness: { scope: :training_session_id }
  validate :same_beneficiary_and_service_date
  before_destroy :retain_claimed_link

  private

  def same_beneficiary_and_service_date
    return unless training_session && equipment_item

    errors.add(:equipment_item, 'must belong to the training beneficiary') unless equipment_item.application_id == training_session.application_id
    if training_session.completed_at && equipment_item.delivered_on && equipment_item.delivered_on > training_session.completed_at.to_date
      errors.add(:equipment_item, 'was not supplied by the training date')
    end
    errors.add(:training_session, 'claimed equipment links require correction') if training_session.icc_claimed? && !training_session.icc_correction_write
  end

  def retain_claimed_link
    return unless training_session.icc_claimed? && !training_session.icc_correction_write

    errors.add(:base, 'Claimed equipment links require correction')
    throw :abort
  end
end
