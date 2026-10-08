# frozen_string_literal: true

module Vouchers
  # Checks who may redeem (feature, vendor approval, identity verification) and the form input
  # (amount, products, submission ID). Voucher#redeem! owns the spending checks and the transaction,
  # under the voucher lock, so a replayed submission returns its original purchase even after the
  # balance or status has changed.
  class RedemptionService < BaseService
    attr_reader :voucher, :vendor, :amount, :product_ids, :notes, :session, :submission_id

    # @param voucher [Voucher] The voucher to redeem
    # @param vendor [User] The vendor processing the redemption
    # @param amount [String] The amount as typed; see MoneyInput
    # @param product_ids [Array<String>] Array of product IDs
    # @param submission_id [String] Identifier of this redemption form submission
    # @param notes [String] Optional notes about the redemption
    # @param session [ActionDispatch::Request::Session] The session for identity verification check
    # @return [Result] Success or failure result with transaction data or error message
    def self.call(voucher:, vendor:, amount:, product_ids:, session:, submission_id:, notes: nil) # rubocop:disable Metrics/ParameterLists
      new(voucher: voucher, vendor: vendor, amount: amount, product_ids: product_ids, notes: notes, session: session,
          submission_id: submission_id).call
    end

    def initialize(voucher:, vendor:, amount:, product_ids:, session:, submission_id:, notes: nil) # rubocop:disable Metrics/ParameterLists
      super()
      @voucher = voucher
      @vendor = vendor
      @raw_amount = amount
      @amount = MoneyInput.parse(amount)
      @product_ids = Array(product_ids).compact_blank
      @notes = notes
      @session = session
      @submission_id = submission_id.to_s.strip.presence
    end

    def call
      return failure('Voucher functionality is currently disabled') unless FeatureFlag.enabled?(:vouchers_enabled)
      return failure(I18n.t('alerts.vendor_not_approved_for_vouchers')) unless vendor.can_process_vouchers?
      return failure('Identity verification is required before redemption', { error_type: :identity_verification_required }) unless identity_verified?

      problem = input_problem
      return failure(problem, { error_type: :invalid_input }) if problem

      transaction = voucher.redeem!(amount, vendor, build_product_data, notes: notes, submission_id: submission_id)
      return failure(refusal_message, { error_type: :refused }) unless transaction

      success('Voucher successfully processed', { transaction: transaction, voucher: voucher })
    rescue Voucher::SubmissionConflict
      failure('This form was already used for a different purchase. Start a new redemption.', { error_type: :submission_conflict })
    rescue StandardError => e
      log_error(e, { voucher_id: voucher&.id, vendor_id: vendor&.id, amount: amount&.to_s })
      failure('Unable to process voucher redemption. Please try again.')
    end

    private

    def input_problem
      return 'Reload the redemption form and try again.' if submission_id.blank?
      return 'Enter the amount in dollars and cents, for example 125.50.' if amount.nil?
      return 'Redemption amount must be greater than zero' unless amount.positive?

      'Please select at least one product for this voucher redemption' if product_ids.blank?
    end

    # Voucher#redeem! refuses without a reason; the voucher as it now stands explains why.
    def refusal_message
      voucher.reload
      return 'This voucher is not active or has already been processed' unless voucher.voucher_active? && !voucher.expired?
      return "Cannot redeem more than the available amount (#{formatted_amount(voucher.remaining_value)})" if amount > voucher.remaining_value

      minimum = Policy.voucher_minimum_redemption_amount
      return "The minimum redemption amount is #{formatted_amount(minimum)}" if amount < minimum

      'Unable to process voucher redemption. Please verify the amount and try again.'
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
