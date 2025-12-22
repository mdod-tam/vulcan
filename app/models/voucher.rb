# frozen_string_literal: true

# Represents a voucher that can be redeemed by constituents for assistive technology products
class Voucher < ApplicationRecord
  belongs_to :application
  belongs_to :vendor, optional: true, class_name: 'User'
  belongs_to :invoice, optional: true
  has_many :transactions, class_name: 'VoucherTransaction', dependent: :restrict_with_error
  has_many :events, as: :auditable, dependent: :destroy

  validates :code, presence: true, uniqueness: true
  validates :initial_value, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :remaining_value, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validate :remaining_value_cannot_exceed_initial_value

  before_validation :generate_code, on: :create
  before_validation :set_initial_values, on: :create
  after_update :check_status_changes
  after_update :log_status_change, if: -> { saved_change_to_status? && respond_to?(:events) }

  enum :status, {
    active: 0,      # Initial state when voucher is created and ready to be used
    redeemed: 2,    # When voucher has been fully used
    expired: 3,     # When voucher has passed its expiration date
    cancelled: 4    # When voucher has been cancelled by admin
  }, default: :active, prefix: :voucher

  scope :available, -> { where(status: :active) }
  scope :for_vendor, ->(vendor_id) { where(vendor_id: vendor_id) }
  scope :not_invoiced, -> { where(invoice_id: nil) }
  scope :expiring_soon, lambda {
    expiration_threshold = 7.days
    where(status: :active)
      .where(
        "issued_at + (INTERVAL '1 month' * ?) - CURRENT_TIMESTAMP <= ? * INTERVAL '1 day'",
        Policy.get('voucher_validity_period_months'),
        expiration_threshold.to_i
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

  def activate_if_valid!
    # Don't modify if voucher is already in a final state
    return if %w[redeemed cancelled].include?(status)

    # If voucher is already active, only check if it needs to be marked as expired
    if status == 'active'
      update!(status: :expired) if expired?
      return
    end

    # For any other status, check if it should be expired or active
    if expired?
      update!(status: :expired)
    else
      update!(status: :active)
    end
  end

  # Determines if a voucher can be redeemed based on its internal state and amount.
  # NOTE: This method does NOT perform identity verification (e.g., Date of Birth).
  # Identity verification is handled externally by the VoucherVerificationService
  # as a prerequisite to calling the redemption process.
  def can_redeem?(amount)
    return false unless voucher_active?
    return false if expired?
    return false if amount > remaining_value
    return false if amount < Policy.voucher_minimum_redemption_amount

    true
  end

  # This method handles the financial transaction (redemption) and updates the voucher's state.
  # It assumes that any necessary identity verification (e.g., DOB) has already
  # been performed by an external service (e.g., VoucherVerificationService) prior to this method being called.
  #
  # @param amount [Float] The amount to redeem
  # @param vendor [User] The vendor processing the redemption
  # @param product_data [Hash] Optional hash of {product_id => quantity}
  # @param notes [String] Optional notes about the redemption
  # @return [VoucherTransaction, false] The created transaction or false if redemption fails
  def redeem!(amount, vendor, product_data = nil, notes: nil)
    # Ensure the voucher meets basic redemption criteria (active, not expired, sufficient funds)
    return false unless can_redeem?(amount)

    transaction(requires_new: true) do
      # Create the transaction record
      txn = create_redemption_transaction(amount, vendor, generate_reference_number, notes)

      # Process any products that were purchased
      process_product_data(product_data, txn) if product_data.present?

      # Update voucher state
      update_voucher_after_redemption(amount, vendor)

      # Send notifications and create audit event
      notify_voucher_redemption(txn)
      log_redemption_event(vendor, amount, txn, product_data)

      txn
    end
  end

  def cancel!
    return false unless can_cancel?

    update!(
      status: :cancelled,
      notes: [notes, "Cancelled at #{Time.current}"].compact.join("\n")
    )
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

  # Override to_param to return the voucher code
  def to_param
    code
  end

  def self.calculate_value_for_constituent(constituent)
    Constituent::DISABILITY_TYPES.sum do |disability_type|
      # Explicitly check for true to handle any truthy/falsey values
      if constituent.send("#{disability_type}_disability") == true
        Policy.voucher_value_for_disability(disability_type)
      else
        0
      end
    end
  end

  private

  # Create the transaction record
  def create_redemption_transaction(amount, vendor, reference_number, notes)
    transactions.create!(
      vendor: vendor,
      amount: amount,
      transaction_type: :redemption,
      status: :transaction_completed,
      processed_at: Time.current,
      reference_number: reference_number,
      notes: notes
    )
  end

  # Handle product data
  def process_product_data(product_data, transaction)
    product_data.each do |product_id, quantity|
      product = Product.find(product_id)

      # Create transaction product record
      transaction.voucher_transaction_products.create!(
        product: product,
        quantity: quantity.to_i
      )

      # Associate product with the application if not already associated
      associate_product_with_application(product)
    end
  end

  # Associate product with the application
  def associate_product_with_application(product)
    application.products << product unless application.products.include?(product)
  end

  # Update the voucher's state after redemption
  def update_voucher_after_redemption(amount, vendor)
    self.remaining_value -= amount
    self.last_used_at = Time.current
    self.vendor = vendor

    # Update status if fully redeemed (use epsilon check for floating point precision)
    self.status = :redeemed if remaining_value.zero? || remaining_value.abs < 0.01

    save!
  end

  # Send the redemption notification
  def notify_voucher_redemption(transaction)
    VoucherNotificationsMailer.with(transaction: transaction).voucher_redeemed.deliver_later
  end

  # Create an event record for voucher redemption
  # This method is fault-tolerant - if it fails, it logs the error but doesn't raise an exception
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
        remaining_value: remaining_value,
        products: format_product_data_for_event(product_data)
      }
    )
  rescue StandardError => e
    # Log the error but don't raise - this ensures the transaction still completes
    Rails.logger.error("Failed to log voucher redemption event: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n")) if e.backtrace
    # Return nil but don't raise exception
    nil
  end

  # Format product data for event metadata
  def format_product_data_for_event(product_data)
    return nil if product_data.blank?

    product_data.map do |id, qty|
      { id: id, quantity: qty }
    end
  end

  def check_status_changes
    return unless saved_change_to_status?

    case status
    when 'expired'
      VoucherNotificationsMailer.with(voucher: self).voucher_expired.deliver_later
    end
  end

  def log_status_change
    actor = determine_actor_for_logging
    return unless actor && valid_actor?(actor)

    AuditEventService.log(
      action: "status_changed_to_#{status}",
      actor: actor,
      auditable: self,
      metadata: {
        previous_status: status_before_last_save,
        current_status: status,
        timestamp: Time.current
      }
    )
  rescue StandardError => e
    # Log the error but don't raise - this ensures the voucher operation still completes
    Rails.logger.error("Failed to log voucher status change: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n")) if e.backtrace
    # Return nil but don't raise exception
    nil
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
    actor = Current.user
    return actor if actor.present?

    begin
      User.system_user
    rescue StandardError => e
      Rails.logger.error("Failed to get system user for voucher status change logging: #{e.message}")
      nil
    end
  end

  def valid_actor?(actor)
    return true if actor&.persisted? && User.exists?(actor.id)

    Rails.logger.warn("Skipping voucher status change audit - actor user (ID: #{actor&.id}) does not exist in database")
    false
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
    self.issued_at = Time.current
  end
end
