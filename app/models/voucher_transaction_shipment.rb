# frozen_string_literal: true

# One package for a completed voucher purchase. Written only through
# VoucherTransactions::FulfillmentService; lock_version refuses a correction made from a stale form.
class VoucherTransactionShipment < ApplicationRecord
  include TypedDateInput

  belongs_to :voucher_transaction, inverse_of: :shipments
  belongs_to :created_by, class_name: 'User'
  belongs_to :updated_by, class_name: 'User', optional: true
  # The package's first-tracking notice; see VoucherTransactions::TrackingNotice.
  belongs_to :tracking_notification, class_name: 'Notification', optional: true

  normalizes :tracking_number, with: ->(number) { number.to_s.strip }
  before_validation :normalize_tracking_number

  validates :tracking_number, presence: true, length: { maximum: 64 }
  validates :normalized_tracking_number, uniqueness: { scope: :voucher_transaction_id }
  validates :contents, length: { maximum: 500 }
  typed_date_input :dispatched_on
  validate :dispatched_on_not_in_future

  scope :awaiting_tracking_notice, -> { where(tracking_notification_id: nil) }

  def dispatched?
    dispatched_on.present?
  end

  private

  # Conservative: case, spaces, and hyphens only. Only used to refuse the same package twice.
  def normalize_tracking_number
    self.normalized_tracking_number = tracking_number.to_s.upcase.gsub(/[\s-]/, '')
  end

  def dispatched_on_not_in_future
    errors.add(:dispatched_on, :in_future) if dispatched_on && dispatched_on > Time.zone.today
  end
end
