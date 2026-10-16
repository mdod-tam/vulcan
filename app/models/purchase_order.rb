# frozen_string_literal: true

class PurchaseOrder < ApplicationRecord
  include TypedDateInput

  typed_date_input :sent_at

  belongs_to :vendor, class_name: 'Users::Vendor'
  has_many :equipment_items, dependent: :restrict_with_error
  has_many :events, as: :auditable, dependent: :restrict_with_error

  normalizes :number, with: ->(value) { value.strip }
  before_validation { self.normalized_number = number.to_s.gsub(/\s+/, '').upcase }
  validates :number, :sent_at, presence: true
  validates :number, length: { maximum: 100 }
  validates :normalized_number, uniqueness: { scope: :vendor_id, message: 'is already recorded for this vendor; choose the existing purchase order' }
  validate :date_not_future
  validate :shipment_dates_compatible
  validate :vendor_is_active, if: -> { new_record? || will_save_change_to_vendor_id? }

  scope :recent_first, -> { order(sent_at: :desc, id: :desc) }

  def equipment_history
    Event.where(auditable: self)
         .or(Event.where("metadata->'purchase_order_ids' @> ?::jsonb", [id].to_json))
         .includes(:user).order(created_at: :desc, id: :desc)
  end

  def shipment_status
    items = equipment_items.to_a
    return 'No equipment currently linked' if items.empty?

    shipped = items.count { |item| item.queue_status == 'shipped' }
    return 'Awaiting Shipment' if shipped.zero?

    shipped == items.size ? 'Shipped' : 'Partially Shipped'
  end

  private

  def vendor_is_active
    errors.add(:vendor, 'must be an active vendor') unless vendor&.public_login_active?
  end

  def date_not_future
    errors.add(:sent_at, 'cannot be in the future') if sent_at&.future?
  end

  def shipment_dates_compatible
    return unless persisted? && sent_at && will_save_change_to_sent_at?
    return unless equipment_items.exists?(shipped_at: ...sent_at)

    errors.add(:sent_at, 'cannot be later than a linked shipment date')
  end
end
