# frozen_string_literal: true

module Icanconnect
  module FundedPurchaseOrder
    extend ActiveSupport::Concern
    include Claimable

    included do
      typed_date_input :invoice_on
      has_one_attached :financial_document
      has_many_attached :superseded_financial_documents
      validates :financial_document, :superseded_financial_documents, document: { purpose: :financial_evidence }
      normalizes :vendor_name, with: ->(value) { value.to_s.strip.presence }
      validates :funding_source, inclusion: { in: Icanconnect::FUNDING_SOURCES }
      validates :shipping_cost, :tax_cost, :other_cost, :invoice_total, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
      validate :purchase_funding_retained
    end

    def icc_financial_evidence_locked?
      icc_claimed? || equipment_items.where.not(icc_claimed_at: nil).exists?
    end

    def shared_charge_total
      charges = [shipping_cost, tax_cost, other_cost]
      charges.sum if charges.none?(&:nil?)
    end

    def invoice_reconciled?
      units = equipment_items.to_a
      charges = shared_charge_total
      invoice_total.present? && charges.present? && units.any? &&
        units.all? { |item| item.unit_cost.present? } &&
        units.sum(&:unit_cost) + charges == invoice_total
    end

    private

    def purchase_funding_retained
      errors.add(:funding_source, 'cannot change after purchasing') if persisted? && will_save_change_to_funding_source?
      errors.add(:funding_source, 'ICC shelf stock is outside this workflow') if funding_source == 'icanconnect' && purpose.to_s == 'program_stock'
      errors.add(:other_cost_category, 'is required for other charges') if other_cost.to_d.positive? && other_cost_category.blank?
    end
  end
end
