# frozen_string_literal: true

class EquipmentNeed < ApplicationRecord
  belongs_to :application
  belongs_to :product
  belongs_to :source_evaluation, class_name: 'Evaluation', optional: true

  validates :remaining_quantity, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :product_id, uniqueness: { scope: :application_id }
  validate :source_evaluation_belongs_to_application

  scope :remaining, -> { where('remaining_quantity > 0') }

  private

  def source_evaluation_belongs_to_application
    return unless source_evaluation && source_evaluation.application_id != application_id

    errors.add(:source_evaluation, 'must belong to this application')
  end
end
