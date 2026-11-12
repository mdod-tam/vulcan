# frozen_string_literal: true

# Represents a voucher that can be redeemed by constituents for accessible telecommunications products
class Voucher < ApplicationRecord
  has_many :email_delivery_attempts, as: :origin, dependent: :nullify
  belongs_to :application
  belongs_to :vendor, optional: true, class_name: 'User'
  has_many :transactions, class_name: 'VoucherTransaction', dependent: :restrict_with_error
  has_many :events, as: :auditable, dependent: :restrict_with_error

  validates :code, presence: true, uniqueness: true
  validates :initial_value, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :remaining_value, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validate :remaining_value_cannot_exceed_initial_value

  before_validation :generate_code, on: :create
  before_validation :set_initial_values, on: :create
  before_validation :set_issued_at, on: :create
  after_update :log_status_change, if: :saved_change_to_status?

  enum :status, {
    active: 0,
    redeemed: 1,    # Fully used
    expired: 2,
    cancelled: 3    # Cancelled by an admin
  }, default: :active, prefix: :voucher

  scope :available, -> { where(status: :active) }
  scope :for_vendor, ->(vendor_id) { where(vendor_id: vendor_id) }
  scope :expiring_soon, lambda {
    expiration_threshold = 7.days
    where(status: :active)
      .where(
        "issued_at + (INTERVAL '1 month' * ?) - CURRENT_TIMESTAMP <= ? * INTERVAL '1 day'",
        Policy.get('voucher_validity_period_months'),
        expiration_threshold.in_days
      )
  }

  def expired?
    return true if status == 'expired'

    if issued_at
      issued_at + Policy.voucher_validity_period <= Time.current
    else
      false
    end
  end

  def expiration_date
    issued_at + Policy.voucher_validity_period if issued_at
  end

  def days_until_expiration
    return nil unless issued_at

    ((issued_at + Policy.voucher_validity_period) - Time.current).to_i / 1.day
  end

  # Checks only voucher state and amount. Identity verification (date of birth)
  # occurs before redemption, in VoucherVerificationService.
  def can_redeem?(amount)
    return false unless voucher_active?
    return false if expired?
    return false if amount > remaining_value
    return false if amount < Policy.voucher_minimum_redemption_amount

    true
  end

  # A repeated form submission whose purchase details differ from the purchase it already recorded.
  class SubmissionConflict < StandardError; end

  # Records the redemption and updates the voucher. The caller must verify
  # identity first (see VoucherVerificationService).
  #
  # With a submission_id, a repeat of the same form submission returns the purchase it already
  # recorded, even after the balance or status has changed, and charges nothing again.
  #
  # @param amount [BigDecimal] The amount to redeem
  # @param vendor [User] The vendor processing the redemption
  # @param product_data [Hash] Optional hash of {product_id => quantity}
  # @param notes [String] Optional notes about the redemption
  # @param submission_id [String] Optional identifier of the form submission
  # @return [VoucherTransaction, false] The recorded transaction or false if redemption fails
  # @raise [SubmissionConflict] when submission_id names a purchase with different details
  def redeem!(amount, vendor, product_data = nil, notes: nil, submission_id: nil)
    transaction(requires_new: true) do
      # The row lock makes a concurrent redemption wait, then re-read the balance this one leaves.
      # Checking before the lock would let both spend the same balance.
      lock!
      replayed = submission_id.present? && transactions.find_by(submission_id: submission_id)
      if replayed
        replay_redemption(replayed, amount, vendor, product_data)
      elsif can_redeem?(amount)
        txn = create_redemption_transaction(amount, vendor, generate_reference_number, notes, submission_id)

        process_product_data(product_data, txn) if product_data.present?

        Current.set(user: vendor) { update_voucher_after_redemption(amount, vendor) }

        notify_voucher_redemption(txn)
        log_redemption_event(vendor, amount, txn, product_data)

        txn
      else
        false
      end
    end
  end

  def cancel!(actor:)
    raise ArgumentError, 'actor is required' if actor.blank?

    with_lock(requires_new: true) do
      if can_cancel?
        Current.set(user: actor) do
          update!(status: :cancelled, notes: [notes, "Cancelled at #{Time.current}"].compact.join("\n"))
          AuditEventService.log(action: 'voucher_cancelled', actor: actor, auditable: self,
                                metadata: { operation_id: SecureRandom.uuid, cancelled_at: Time.current.iso8601, notes: notes })
        end
        true
      else
        false
      end
    end
  end

  def can_cancel?
    voucher_active?
  end

  def initial_value=(value)
    super(value.try(:round, 2))
  end

  def remaining_value=(value)
    super(value.try(:round, 2))
  end

  def to_param
    code
  end

  def self.calculate_value_for_constituent(constituent)
    Users::Constituent::DISABILITY_TYPES.sum do |disability_type|
      # Compare with true so that only a true flag adds value.
      if constituent.send("#{disability_type}_disability") == true
        Policy.voucher_value_for_disability(disability_type)
      else
        0
      end
    end
  end

  private

  def create_redemption_transaction(amount, vendor, reference_number, notes, submission_id = nil)
    transactions.create!(
      vendor: vendor,
      amount: amount,
      transaction_type: :redemption,
      status: :transaction_completed,
      processed_at: Time.current,
      reference_number: reference_number,
      notes: notes,
      submission_id: submission_id.presence
    )
  end

  # The same submission must describe the same purchase; anything else is a conflict, not a replay.
  def replay_redemption(original, amount, vendor, product_data)
    submitted_products = (product_data || {}).keys.map(&:to_i).sort
    recorded_products = original.voucher_transaction_products.pluck(:product_id).sort
    unless original.vendor_id == vendor.id && original.amount == amount.to_d && recorded_products == submitted_products
      raise SubmissionConflict, "Submission #{original.submission_id} already recorded a different purchase"
    end

    AuditEventService.log(
      action: 'voucher_redemption_replayed', actor: vendor, auditable: self,
      metadata: { voucher_id: id, transaction_id: original.id, operation_id: SecureRandom.uuid }
    )
    original
  end

  def process_product_data(product_data, transaction)
    product_data.each do |product_id, quantity|
      product = Product.find(product_id)

      transaction.voucher_transaction_products.create!(
        product: product,
        quantity: quantity.to_i
      )
    end
  end

  def update_voucher_after_redemption(amount, vendor)
    self.remaining_value -= amount
    self.last_used_at = Time.current
    self.vendor = vendor

    # The epsilon allows for floating point amounts.
    self.status = :redeemed if remaining_value.zero? || remaining_value.abs < 0.01

    save!
  end

  def notify_voucher_redemption(transaction)
    VoucherNotificationsMailer.with(transaction: transaction).voucher_redeemed.deliver_later
  end

  # The audit is part of the redemption transaction.
  def log_redemption_event(vendor, amount, transaction, product_data)
    AuditEventService.log(
      action: 'voucher_redeemed',
      actor: vendor,
      auditable: self,
      metadata: {
        application_id: application.id,
        voucher_code: code,
        amount: amount,
        vendor_name: vendor.business_name || 'Unknown vendor',
        transaction_id: transaction.id,
        operation_id: "voucher_redemption:#{transaction.id}",
        remaining_value: remaining_value,
        products: format_product_data_for_event(product_data)
      }
    )
  end

  def format_product_data_for_event(product_data)
    return nil if product_data.blank?

    product_data.map do |id, qty|
      { id: id, quantity: qty }
    end
  end

  def log_status_change
    actor = determine_actor_for_logging

    AuditEventService.log(
      action: "status_changed_to_#{status}",
      actor: actor,
      auditable: self,
      metadata: {
        operation_id: SecureRandom.uuid,
        previous_status: status_before_last_save,
        current_status: status,
        timestamp: Time.current
      }
    )
  end

  def remaining_value_cannot_exceed_initial_value
    return unless remaining_value && initial_value && remaining_value > initial_value

    errors.add(:remaining_value, 'cannot exceed initial value')
  end

  def generate_code
    return if code.present?

    loop do
      self.code = SecureRandom.alphanumeric(12).upcase
      break unless Voucher.exists?(code: code)
    end
  end

  def generate_reference_number
    "TXN-#{SecureRandom.hex(6).upcase}"
  end

  def determine_actor_for_logging
    Current.user.presence || PublicAuditActor.system_audit_actor!
  end

  # Expiry counts from issued_at; a voucher without one never expires.
  def set_issued_at
    self.issued_at ||= Time.current
  end

  def set_initial_values
    return if initial_value.present? && remaining_value.present?

    if application&.user
      total_value = self.class.calculate_value_for_constituent(application.user)
      self.initial_value = total_value
      self.remaining_value = total_value
    else
      self.initial_value = 0
      self.remaining_value = 0
    end
  end
end
