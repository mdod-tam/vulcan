# frozen_string_literal: true

class BidGroupLine < ApplicationRecord
  belongs_to :bid_group
  belongs_to :product
  belongs_to :equipment_need, optional: true
  belongs_to :equipment_item, optional: true
  has_many :acquired_items, class_name: 'EquipmentItem', foreign_key: :acquisition_bid_group_line_id,
                            inverse_of: :acquisition_bid_group_line, dependent: :restrict_with_error
  validates :quantity, numericality: { only_integer: true, greater_than: 0 }
  validate :source_matches_purpose
  validate :awarded_line_is_fixed
  scope :reserved, -> { joins(:bid_group).where(released_at: nil, bid_groups: { cancelled_at: nil, purchase_order_id: nil }) }

  def reserved?
    released_at.nil? && bid_group.open?
  end

  def application
    equipment_need&.application || equipment_item&.application
  end

  private

  def awarded_line_is_fixed
    return unless persisted? && bid_group.purchase_order_id?
    return unless changed.intersect?(%w[bid_group_id product_id equipment_need_id equipment_item_id quantity supplier_setup_group released_at])

    errors.add(:base, 'Awarded bid lines retain the original purchasing instructions')
  end

  def source_matches_purpose
    sources = [equipment_need, equipment_item].compact
    if bid_group.program_stock?
      errors.add(:base, 'Stock lines cannot reserve application requests') if sources.any?
    elsif sources.size != 1
      errors.add(:base, 'Direct lines must reserve one application request')
    end
    errors.add(:product, 'must match the reserved request') if sources.any? { |source| source.product_id != product_id }
    errors.add(:quantity, 'must be one for a detached device') if equipment_item && quantity != 1
    return if supplier_setup_group.blank? || Product::PROGRAM_GROUPS.key?(supplier_setup_group)

    errors.add(:supplier_setup_group, 'is not a program group')
  end
end
