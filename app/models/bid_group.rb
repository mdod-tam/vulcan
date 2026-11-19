# frozen_string_literal: true

class BidGroup < ApplicationRecord
  include Icanconnect::FundedBidGroup

  PURPOSES = { direct_to_constituents: 'direct_to_constituents', program_stock: 'program_stock' }.freeze
  enum :purpose, PURPOSES, validate: true
  belongs_to :purchase_order, optional: true
  has_many :bid_group_lines, dependent: :restrict_with_error
  has_many :events, as: :auditable, dependent: :restrict_with_error
  normalizes :number, with: ->(value) { value.to_s.strip }
  before_validation { self.normalized_number = number.to_s.gsub(/\s+/, '').upcase }
  validates :number, presence: true, length: { maximum: 100 }
  validates :normalized_number, uniqueness: true
  validate :purpose_is_fixed
  scope :open, -> { where(cancelled_at: nil, purchase_order_id: nil) }
  scope :awaiting_award, -> { open.where(id: BidGroupLine.where(released_at: nil).select(:bid_group_id)) }

  def active_lines
    bid_group_lines.where(released_at: nil)
  end

  def equipment_history
    Event.where(auditable: self).or(Event.with_metadata(:bid_group_ids, [id])).includes(:user).order(created_at: :desc, id: :desc)
  end

  def open?
    cancelled_at.nil? && purchase_order_id.nil?
  end

  private

  def purpose_is_fixed
    errors.add(:purpose, 'cannot change after lines exist') if persisted? && will_save_change_to_purpose? && bid_group_lines.exists?
  end
end
