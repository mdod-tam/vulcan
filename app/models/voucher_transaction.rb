# frozen_string_literal: true

class VoucherTransaction < ApplicationRecord
  include Groupdate

  belongs_to :voucher
  belongs_to :vendor, class_name: 'User'
  belongs_to :invoice, optional: true

  has_many :voucher_transaction_products, dependent: :destroy
  has_many :products, through: :voucher_transaction_products
  has_many :shipments, -> { order(:created_at, :id) }, class_name: 'VoucherTransactionShipment',
                                                       dependent: :restrict_with_error, inverse_of: :voucher_transaction

  validates :amount, presence: true,
                     numericality: { greater_than: 0 }
  validates :reference_number, presence: true, uniqueness: true
  validates :processed_at, presence: true
  # A transaction records money that moved. It is checked against the voucher's balance once, when
  # created; the balance falls with later redemptions, so a later save (such as invoicing) must not
  # re-check it. Its money fields therefore never change once saved.
  validate :amount_within_voucher_limit?, if: :redemption?, on: :create
  attr_readonly :voucher_id, :vendor_id, :amount, :transaction_type, :reference_number, :processed_at

  before_validation :set_processed_at, on: :create
  before_validation :generate_reference_number, on: :create

  enum :transaction_type, {
    redemption: 0, # Standard redemption of voucher value
    refund: 1,         # Refund of previously redeemed amount
    adjustment: 2      # Administrative adjustment
  }, default: :redemption

  enum :status, {
    transaction_pending: 0,       # Transaction is pending processing
    transaction_completed: 1,     # Transaction has been completed successfully
    transaction_failed: 2,        # Transaction failed to process
    transaction_cancelled: 3      # Transaction was cancelled
  }, default: :transaction_pending

  # How a completed purchase reaches the constituent. Set through VoucherTransactions::FulfillmentService.
  enum :fulfillment_mode, { unspecified: 0, shipping: 1, local_pickup: 2 }, prefix: :fulfillment

  scope :completed, -> { where(status: :transaction_completed) }
  # Only a completed redemption is a purchase that can be shipped; refunds and adjustments are not.
  scope :fulfillable, -> { completed.redemption }
  # The list form of needs_shipping_details?.
  scope :needing_shipping_details, lambda {
    without_packages = fulfillment_shipping.where.not(id: VoucherTransactionShipment.select(:voucher_transaction_id))
    fulfillable.merge(fulfillment_unspecified.or(without_packages))
  }
  # Completed purchases on applications the user may open: their own, or ones they manage.
  scope :purchases_visible_to, lambda { |user|
    fulfillable.joins(:voucher)
               .where(vouchers: { application_id: Application.accessible_by(user).select(:id) })
               .includes(:vendor, :shipments, voucher: { application: :user })
               .order(processed_at: :desc, id: :desc)
  }
  scope :pending_invoice, -> { completed.where(invoice_id: nil) }
  scope :for_vendor, ->(vendor_id) { where(vendor_id: vendor_id) }
  scope :in_date_range, lambda { |start_date, end_date|
    where(processed_at: start_date.beginning_of_day..end_date.end_of_day)
  }

  # Class methods for reporting
  def self.total_amount_for_vendor(vendor_id, start_date = nil, end_date = nil)
    scope = completed.for_vendor(vendor_id)
    scope = scope.in_date_range(start_date, end_date) if start_date && end_date
    BigDecimal(scope.sum(:amount).to_s).to_i
  end

  def self.transaction_counts_by_status(vendor_id = nil)
    scope = vendor_id ? where(vendor_id: vendor_id) : all
    scope.group(:status).count.with_indifferent_access
  end

  def self.daily_totals(start_date, end_date, vendor_id = nil)
    scope = completed.in_date_range(start_date, end_date)
    scope = scope.where(vendor_id: vendor_id) if vendor_id
    scope.group_by_day(:processed_at).sum(:amount).transform_values { |v| BigDecimal(v.to_s).to_i }
  end

  def fulfillable?
    transaction_completed? && redemption?
  end

  # No mode chosen yet, or shipping chosen without any package recorded. Pickup needs nothing.
  def needs_shipping_details?
    fulfillable? && (fulfillment_unspecified? || (fulfillment_shipping? && shipments.none?))
  end

  def amount=(value)
    super(value.try(:to_d))
  end

  private

  def amount_within_voucher_limit?
    return true unless voucher && amount && redemption?

    if BigDecimal(amount.to_s) > BigDecimal(voucher.remaining_value.to_s)
      errors.add(:amount, 'exceeds remaining voucher value')
      false
    else
      true
    end
  end

  def set_processed_at
    self.processed_at ||= Time.current
  end

  def generate_reference_number
    return if reference_number.present?

    # Format: TX-[voucher-code-part]-[timestamp]-[random]
    voucher_code = voucher&.code
    voucher_part = voucher_code&.first(6)&.upcase || 'NOTX'
    timestamp = Time.current.strftime('%y%m%d%H%M')
    random = SecureRandom.hex(3).upcase

    self.reference_number = "TX-#{voucher_part}-#{timestamp}-#{random}"
  end
end
