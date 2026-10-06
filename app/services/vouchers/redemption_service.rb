# frozen_string_literal: true

module Vouchers
  # The service validates vendor and session eligibility. Voucher#redeem! owns the transaction.
  class RedemptionService < BaseService
    attr_reader :voucher, :vendor, :amount, :product_ids, :notes, :session

    # @param voucher [Voucher] The voucher to redeem
    # @param vendor [User] The vendor processing the redemption
    # @param amount [String, Float] The amount to redeem
    # @param product_ids [Array<String>] Array of product IDs
    # @param notes [String] Optional notes about the redemption
    # @param session [ActionDispatch::Request::Session] The session for identity verification check
    # @return [Result] Success or failure result with transaction data or error message
    def self.call(voucher:, vendor:, amount:, product_ids:, session:, notes: nil) # rubocop:disable Metrics/ParameterLists
      new(voucher: voucher, vendor: vendor, amount: amount, product_ids: product_ids, notes: notes, session: session).call
    end

    def initialize(voucher:, vendor:, amount:, product_ids:, session:, notes: nil) # rubocop:disable Metrics/ParameterLists
      super()
      @voucher = voucher
      @vendor = vendor
      @amount = amount.to_f
      @product_ids = Array(product_ids).compact
      @notes = notes
      @session = session
    end

    def call # rubocop:disable Metrics/AbcSize
      return failure('Voucher functionality is currently disabled') unless FeatureFlag.enabled?(:vouchers_enabled)

      return failure(I18n.t('alerts.vendor_not_approved_for_vouchers')) unless vendor.can_process_vouchers?
      return failure('This voucher is not active or has already been processed') unless voucher_active?
      return failure('Identity verification is required before redemption', { error_type: :identity_verification_required }) unless identity_verified?

      return failure('Redemption amount must be greater than zero') if amount <= 0
      return failure("Cannot redeem more than the available amount (#{formatted_amount(voucher.remaining_value)})") if amount > voucher.remaining_value
      return failure('Please select at least one product for this voucher redemption') if product_ids.blank?

      product_data = build_product_data

      transaction = voucher.redeem!(amount, vendor, product_data, notes: notes)

      if transaction
        success('Voucher successfully processed', { transaction: transaction, voucher: voucher })
      else
        failure('Unable to process voucher redemption. Please verify the amount and try again.')
      end
    rescue StandardError => e
      log_error(e, {
                  voucher_id: voucher&.id,
                  vendor_id: vendor&.id,
                  amount: amount
                })
      failure("Error processing voucher: #{e.message}")
    end

    private

    def voucher_active?
      voucher.voucher_active?
    end

    def identity_verified?
      session[:verified_vouchers].present? &&
        session[:verified_vouchers].include?(voucher.id)
    end

    # The form collects product IDs without quantities, so each product has quantity 1.
    def build_product_data
      product_ids.each_with_object({}) do |product_id, hash|
        hash[product_id.to_s] = 1
      end
    end

    def formatted_amount(value)
      ActionController::Base.helpers.number_to_currency(value)
    end
  end
end
