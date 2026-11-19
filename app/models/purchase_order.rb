# frozen_string_literal: true

class PurchaseOrder < ApplicationRecord
  StockReceiptCounts = Data.define(:ordered, :received, :cancelled, :outstanding)
  include TypedDateInput
  include EquipmentShipping
  include Icanconnect::FundedPurchaseOrder

  typed_date_input :sent_at
  enum :purpose, BidGroup::PURPOSES, validate: true
  has_many :equipment_items, dependent: :restrict_with_error
  has_many :bid_groups, dependent: :restrict_with_error
  has_many :events, as: :auditable, dependent: :restrict_with_error
  normalizes :number, with: ->(value) { value.to_s.strip }
  before_validation { self.normalized_number = number.to_s.gsub(/\s+/, '').upcase }
  validates :number, presence: true, length: { maximum: 100 }
  validates :normalized_number, uniqueness: { message: 'is already recorded; explicitly select the existing unsent order' }
  validate :sent_date_not_future
  validate :purpose_is_fixed
  validate :sent_date_matches_fulfillment
  scope :recent_first, -> { order(created_at: :desc, id: :desc) }
  scope :unsent, -> { where(sent_at: nil) }
  scope :ready_to_send, -> { unsent.joins(:equipment_items).merge(EquipmentItem.active).distinct }

  def equipment_history
    Event.where(auditable: self).or(Event.with_metadata(:purchase_order_ids, [id]))
         .includes(:user).order(created_at: :desc, id: :desc)
  end

  def selection_label
    counts = "#{equipment_items.size} units / #{equipment_items.map(&:application_id).compact.uniq.size} applications"
    "#{number} · #{purpose.humanize} · #{created_at&.to_date} · #{sent_at ? "Sent #{sent_at}" : 'PO sent date needed'} · #{counts}"
  end

  def shipment_status
    return stock_receipt_status if program_stock?

    items = equipment_items.to_a
    active = items.reject(&:withdrawn_at?)
    return 'Cancelled' if items.any? && active.empty?
    return 'No equipment currently linked' if active.empty?
    return 'PO sent date needed' unless sent_at

    completed = active.count(&:shipped_at?)
    return 'Shipping info needed' if completed.zero?
    return 'Partially shipped' if completed < active.size

    completion_label(cancelled: active.size < items.size)
  end

  def stock_receipt_counts(items = equipment_items.to_a)
    received = items.count(&:stock_received_on?)
    cancelled = items.count { |item| item.withdrawn_at? && !item.stock_received_on? }
    StockReceiptCounts.new(ordered: items.size, received:, cancelled:, outstanding: items.size - received - cancelled)
  end

  private

  def stock_receipt_status
    counts = stock_receipt_counts
    return 'No equipment currently linked' if counts.ordered.zero?
    return 'Cancelled' if counts.cancelled == counts.ordered
    return 'PO sent date needed' unless sent_at
    return 'Awaiting stock receipt' if counts.received.zero?
    return 'Partially received' if counts.outstanding.positive?

    completion_label(cancelled: counts.cancelled.positive?)
  end

  def completion_label(cancelled:)
    return 'Closed with cancellations' if cancelled

    program_stock? ? 'Received' : 'Shipment recorded'
  end

  def sent_date_not_future
    errors.add(:sent_at, 'cannot be in the future') if sent_at&.future?
  end

  def purpose_is_fixed
    return unless persisted? && will_save_change_to_purpose? && (equipment_items.exists? || bid_groups.exists?)

    errors.add(:purpose, 'cannot change after purchasing assignments exist')
  end

  def sent_date_matches_fulfillment
    return unless will_save_change_to_sent_at? && persisted?

    linked = equipment_items
    if sent_at.nil? && fulfillment_recorded?(linked)
      errors.add(:sent_at, 'cannot be cleared while shipments or stock receipts exist')
    elsif sent_at && linked.exists?(['shipped_at < ? OR stock_received_on < ?', sent_at, sent_at])
      errors.add(:sent_at, 'cannot follow a linked shipment or stock receipt')
    end
    errors.add(:base, 'An empty order cannot be sent') if sent_at && sent_at_in_database.nil? && linked.active.empty?
  end

  def fulfillment_recorded?(items)
    items.where.not(shipped_at: nil).or(items.where.not(stock_received_on: nil)).exists?
  end
end
