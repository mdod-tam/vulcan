# frozen_string_literal: true

module Icanconnect
  module FundedEquipment
    extend ActiveSupport::Concern
    include Claimable

    included do
      typed_date_input :delivered_on
      typed_date_input :installed_on
      validates :funding_source, inclusion: { in: Icanconnect::FUNDING_SOURCES }
      validates :unit_cost, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
      validate :equipment_funding_consistent
      validate :equipment_evidence_dates_consistent
    end

    def icc_financial_evidence_locked?
      icc_claimed? || (purchase_order&.icc_financial_evidence_locked? || false)
    end

    def icc_receipt_evidence_locked?
      icc_claimed? || icc_claimed_at_in_database.present? || (purchase_order&.icc_claimed? || false)
    end

    private

    def icc_protected_financial_attributes
      return super if icc_claimed? || icc_claimed_at_in_database

      editable_dates = %w[shipped_at installed_on]
      editable_dates << 'delivered_on' unless icc_receipt_evidence_locked?
      super - editable_dates
    end

    def equipment_funding_consistent
      errors.add(:funding_source, 'cannot change after purchasing') if persisted? && will_save_change_to_funding_source? && !assigning_purchase_funding?
      errors.add(:funding_source, 'must match the purchase order') if purchase_order && funding_source != purchase_order.funding_source
      return unless funding_source == 'icanconnect' && new_funding_assignment?
      return errors.add(:application, 'ICC stock is outside this workflow') unless application

      Funding.validate!(application, source: funding_source)
    rescue ArgumentError => e
      errors.add(:funding_source, e.message)
    end

    def assigning_purchase_funding?
      direct_vendor? && purchase_order_id_in_database.nil? && purchase_order_id.present? && shipped_at_in_database.nil?
    end

    def new_funding_assignment?
      new_record? || will_save_change_to_application_id? || (will_save_change_to_purchase_order_id? && purchase_order_id.present?)
    end

    def equipment_evidence_dates_consistent
      validate_evidence_date(:delivered_on, shipped_at, 'shipment')
      validate_evidence_date(:installed_on, delivered_on, 'delivery')
    end

    def validate_evidence_date(field, prerequisite, event)
      date = public_send(field)
      return unless date

      errors.add(field, 'cannot be in the future') if date.future?
      if prerequisite.nil?
        errors.add(field, "requires a recorded #{event} date")
      elsif date < prerequisite
        errors.add(field, "cannot precede #{event}")
      end
    end
  end
end
