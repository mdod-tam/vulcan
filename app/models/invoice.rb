# frozen_string_literal: true

class Invoice < ApplicationRecord
  has_many :email_delivery_attempts, as: :origin, dependent: :nullify
  belongs_to :vendor, class_name: 'User'
  has_many :voucher_transactions, dependent: :nullify
  has_many :events, as: :auditable, dependent: :destroy

  validates :start_date, presence: true
  validates :end_date, presence: true
  validates :total_amount, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :invoice_number, presence: true, uniqueness: true
  validate :end_date_after_start_date
  validate :dates_do_not_overlap_for_vendor

  before_validation :generate_invoice_number, on: :create
  before_validation :calculate_total_amount, on: :create

  enum :status, {
    invoice_draft: 0,        # Initial state when invoice is created
    invoice_pending: 1,      # Ready for review and processing
    invoice_approved: 2,     # Approved for payment
    invoice_paid: 3,         # Payment has been processed
    invoice_cancelled: 4     # Invoice has been cancelled
  }, prefix: true

  scope :unpaid, -> { where.not(status: %i[invoice_paid invoice_cancelled]) }
  scope :for_vendor, ->(vendor_id) { where(vendor_id: vendor_id) }
  scope :in_date_range, lambda { |start_date, end_date|
    where('start_date >= ? AND end_date <= ?', start_date, end_date)
  }
  scope :needs_processing, -> { where(status: :invoice_pending) }

  validates :gad_invoice_reference, presence: true, if: :status_invoice_paid?

  before_save :set_timestamps
  after_save :send_payment_notification, if: :payment_details_added?

  private

  def set_timestamps
    self.approved_at = Time.current if status_changed? && status_invoice_approved?

    return unless status_changed? && status_invoice_paid? && gad_invoice_reference.present?

    self.payment_recorded_at = Time.current
  end

  def payment_details_added?
    saved_change_to_status? && status_invoice_paid? && gad_invoice_reference.present?
  end

  def send_payment_notification
    # Payment settles the vendor's invoice only. Transactions were already completed when invoiced,
    # and a voucher's balance and status belong to its constituent, so neither changes here.
    VendorNotificationsMailer.with(invoice: self).payment_issued.deliver_later
  end

  def total_transaction_amount
    voucher_transactions.sum(:amount)
  end

  def generate_invoice_number
    return if invoice_number.present?

    date_part = Time.current.strftime('%Y%m')
    sequence = (self.class.where('invoice_number LIKE ?', "INV-#{date_part}-%")
      .count + 1).to_s.rjust(4, '0')

    self.invoice_number = "INV-#{date_part}-#{sequence}"
  end

  def calculate_total_amount
    self.total_amount = total_transaction_amount
  end

  def end_date_after_start_date
    return unless start_date && end_date

    return unless end_date <= start_date

    errors.add(:end_date, 'must be after start date')
  end

  def dates_do_not_overlap_for_vendor
    return unless start_date && end_date && vendor_id

    overlapping = self.class
                      .where(vendor_id: vendor_id)  # Only check same vendor
                      .where.not(id: id)            # Exclude self when updating
                      .exists?(['start_date < ? AND end_date > ?', end_date, start_date]) # a shared boundary is not overlap

    return unless overlapping

    errors.add(:base, 'Date range overlaps with an existing invoice')
  end
end
