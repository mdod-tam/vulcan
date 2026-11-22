# frozen_string_literal: true

module Icanconnect
  module ServiceCost
    extend ActiveSupport::Concern
    include Claimable

    included do
      has_one_attached :financial_document
      has_many_attached :superseded_financial_documents
      validates :financial_document, :superseded_financial_documents, document: { purpose: :financial_evidence }
      validates :funding_source, inclusion: { in: Icanconnect::FUNDING_SOURCES }, allow_nil: true
      validates :hourly_rate, :billable_hours, :mileage, :mileage_rate, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
      validate :mileage_rate_is_precise
      validate :icc_service_funding_eligible
    end

    def actual_service_cost
      labor = hourly_service_cost
      return unless labor
      return labor unless mileage&.positive?

      travel = mileage_cost
      labor + travel if travel
    end

    def hourly_service_cost
      return unless hourly_rate.present? && billable_hours.present?

      (hourly_rate * billable_hours).round(2)
    end

    def mileage_cost
      return if mileage.nil?
      return BigDecimal('0') if mileage.zero?
      return if mileage_rate.nil?

      (mileage * mileage_rate).round(2)
    end

    def service_source_on
      funding_service_on || try(:appointment_completed_at)&.to_date || try(:completed_at)&.to_date || created_at&.to_date || Date.current
    end

    private

    def mileage_rate_is_precise
      value = mileage_rate_before_type_cast
      return if value.blank? || MileageRate.parse(value)

      errors.add(:mileage_rate, 'must be a dollar amount with up to three decimal places')
    end

    def icc_service_funding_eligible
      return unless funding_source == 'icanconnect' && (new_record? || will_save_change_to_funding_source? || will_save_change_to_funding_service_on?)

      Icanconnect::Funding.validate!(application, source: funding_source, on: service_source_on)
    rescue Icanconnect::Funding::Ineligible => e
      errors.add(:funding_source, e.message)
    end
  end
end
