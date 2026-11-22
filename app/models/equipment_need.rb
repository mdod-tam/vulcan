# frozen_string_literal: true

class EquipmentNeed < ApplicationRecord
  has_many :bid_group_lines, dependent: :restrict_with_error
  belongs_to :application
  belongs_to :product
  belongs_to :source_evaluation, class_name: 'Evaluation', optional: true

  validates :remaining_quantity, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :product_id, uniqueness: { scope: :application_id }
  validates :disability_setup_group, inclusion: { in: ->(_) { Product::PROGRAM_GROUPS.keys } }, allow_nil: true
  validate :source_evaluation_belongs_to_application

  scope :remaining, -> { where('remaining_quantity > 0') }

  def reserved_quantity
    if bid_group_lines.loaded?
      bid_group_lines.select(&:reserved?).sum(&:quantity)
    else
      bid_group_lines.reserved.sum(:quantity)
    end
  end

  def available_quantity
    remaining_quantity - reserved_quantity
  end

  def setup_ready?
    remaining_quantity.zero? || application.program_disability_groups.include?(disability_setup_group)
  end

  private

  def source_evaluation_belongs_to_application
    return unless source_evaluation && source_evaluation.application_id != application_id

    errors.add(:source_evaluation, 'must belong to this application')
  end
end
