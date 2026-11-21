# frozen_string_literal: true

module Icanconnect
  # Shared invariants for the five actual cost owners, not a second claim ledger.
  module Claimable
    extend ActiveSupport::Concern

    MARK_FIELDS = %w[icc_claim_period icc_external_filing_reference icc_claimed_at icc_claimed_by_id].freeze

    included do
      belongs_to :icc_claimed_by, class_name: 'User', optional: true
      attr_accessor :icc_financial_write, :icc_correction_write

      validate :claimed_evidence_unchanged
      before_destroy :retain_claimed_cost
    end

    def icc_claimed? = icc_claimed_at.present?

    def icc_financial_evidence_locked? = icc_claimed?

    def icc_financial_attributes
      (MARK_FIELDS + %w[funding_source application_id purchase_order_id product_id equipment_item_id category
                        unit_cost shipping_cost tax_cost other_cost other_cost_category invoice_total invoice_on vendor_name vendor_invoice_number
                        hourly_rate billable_hours mileage mileage_rate funding_service_on service_date amount delivered_on installed_on
                        completed_at duration_hours evaluation_date withdrawn_at fulfillment_source replaced_by_equipment_item_id
                        shipped_at]).select { |field| has_attribute?(field) }
    end

    private

    def icc_protected_financial_attributes
      icc_financial_attributes
    end

    def claimed_evidence_unchanged
      changes = changed & icc_financial_attributes
      errors.add(:base, 'Filing markers change only through the reviewed filing action') if changes.intersect?(MARK_FIELDS) && !icc_financial_write
      errors.add(:funding_source, 'must remain iCanConnect until the filed status is removed through a correction') if icc_claimed? && funding_source != 'icanconnect'
      return unless icc_financial_evidence_locked? && !icc_correction_write

      protected_changes = changes & icc_protected_financial_attributes
      protected_changes -= MARK_FIELDS unless icc_claimed_at_in_database
      return unless protected_changes.any? || attachment_changes.any?

      errors.add(:base, 'Claimed costs and shared invoice evidence require an audited filing correction')
    end

    def retain_claimed_cost
      return unless icc_financial_evidence_locked?

      errors.add(:base, 'Claimed evidence must be retained')
      throw :abort
    end
  end
end
