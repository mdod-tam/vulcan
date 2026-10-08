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

  before_validation :generate_invoice_number, on: :create
  before_validation :calculate_total_amount, on: :create

  enum :status, {
    invoice_draft: 0,        # Initial state when invoice is created
    invoice_pending: 1,      # Ready for review and processing
    invoice_approved: 2,     # Approved for payment
    invoice_paid: 3,         # Payment has been processed
    invoice_cancelled: 4     # Withdrawn: its purchases were released for a later invoice
  }, prefix: true

  enum :payment_method, { direct_deposit: 0, eft: 1, check: 2 }, prefix: :paid_by, validate: { allow_nil: true }

  # Invoices::Workflow is the writer for these transitions; the model refuses any other.
  ALLOWED_TRANSITIONS = {
    'invoice_draft' => %w[invoice_pending invoice_cancelled],
    'invoice_pending' => %w[invoice_approved invoice_cancelled],
    'invoice_approved' => %w[invoice_paid invoice_cancelled],
    'invoice_paid' => [],
    'invoice_cancelled' => []
  }.freeze
  # What the vendor was billed. Fixed once the invoice is approved, paid, or withdrawn.
  BILLED_FACTS = %w[vendor_id total_amount start_date end_date invoice_number].freeze
  # How it was settled. Fixed once paid; corrections are audited notes, never edits.
  SETTLEMENT_FACTS = %w[payment_date payment_method payment_reference check_number gad_invoice_reference
                        paid_by_id payment_recorded_at payment_notes].freeze
  SETTLED_STATUSES = %w[invoice_approved invoice_paid invoice_cancelled].freeze

  belongs_to :paid_by, class_name: 'User', optional: true

  scope :unpaid, -> { where.not(status: %i[invoice_paid invoice_cancelled]) }
  scope :for_vendor, ->(vendor_id) { where(vendor_id: vendor_id) }
  scope :in_date_range, lambda { |start_date, end_date|
    where('start_date >= ? AND end_date <= ?', start_date, end_date)
  }
  scope :needs_processing, -> { where(status: :invoice_pending) }

  validates :gad_invoice_reference, presence: true, if: :status_invoice_paid?
  validate :status_transition_allowed, on: :update, if: :will_save_change_to_status?
  validate :billed_facts_unchanged, on: :update
  validate :settlement_facts_unchanged, on: :update
  # Records created already paid (seeds, imports of historical payments) keep whatever was known.
  validate :payment_fully_recorded, on: :update, if: -> { will_save_change_to_status?(to: 'invoice_paid') }

  before_destroy :keep_issued_invoices

  # A number that does not depend on how many invoices exist, so deletions and concurrent runs cannot
  # make two invoices compete for it. Invoices::GenerationService retries the rare random collision.
  def self.generate_number(now = Time.current)
    "INV-#{now.strftime('%Y%m')}-#{SecureRandom.hex(4).upcase}"
  end

  # The last day the invoice covers. New invoices end at an exclusive midnight cutoff; older ones end at
  # 23:59:59 of their last day. Both read correctly here.
  def covered_through
    (end_date - 1.second).to_date
  end

  def period_label(format: '%B %-d, %Y')
    "#{start_date.to_date.strftime(format)} through #{covered_through.strftime(format)}"
  end

  private

  def total_transaction_amount
    voucher_transactions.sum(:amount)
  end

  def generate_invoice_number
    self.invoice_number = self.class.generate_number if invoice_number.blank?
  end

  def calculate_total_amount
    self.total_amount = total_transaction_amount
  end

  def status_transition_allowed
    from = stored_status || status_in_database
    return if ALLOWED_TRANSITIONS.fetch(from, []).include?(status)

    errors.add(:status, "cannot change from #{from.delete_prefix('invoice_').humanize.downcase} " \
                        "to #{status.delete_prefix('invoice_').humanize.downcase}")
  end

  # Read from the database, not from this object: a copy loaded before approval must not rewrite
  # what an approved invoice billed.
  def billed_facts_unchanged
    changed_facts = BILLED_FACTS & changed
    return if changed_facts.empty? || SETTLED_STATUSES.exclude?(stored_status)

    changed_facts.each { |field| errors.add(field, 'cannot change after the invoice is approved') }
  end

  def settlement_facts_unchanged
    changed_facts = SETTLEMENT_FACTS & changed
    return if changed_facts.empty? || stored_status != 'invoice_paid'

    changed_facts.each { |field| errors.add(field, 'cannot change after payment is recorded') }
  end

  def stored_status
    self.class.where(id: id).pick(:status)&.then { |value| self.class.statuses.key(value) || value }
  end

  def payment_fully_recorded
    errors.add(:payment_date, "can't be blank") if payment_date.blank?
    errors.add(:payment_date, "can't be in the future") if payment_date.present? && payment_date.to_date > Date.current
    errors.add(:payment_method, "can't be blank") if payment_method.blank?
    errors.add(:paid_by, "can't be blank") if paid_by_id.blank?
    if paid_by_check?
      errors.add(:check_number, "can't be blank") if check_number.blank?
    elsif payment_method.present? && payment_reference.blank?
      errors.add(:payment_reference, "can't be blank")
    end
  end

  # Issued invoices are financial records; only a draft may be deleted.
  def keep_issued_invoices
    return if status_invoice_draft?

    errors.add(:base, 'An issued invoice cannot be deleted')
    throw :abort
  end

  def end_date_after_start_date
    return unless start_date && end_date

    return unless end_date <= start_date

    errors.add(:end_date, 'must be after start date')
  end
end
