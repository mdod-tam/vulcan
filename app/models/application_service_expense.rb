# frozen_string_literal: true

class ApplicationServiceExpense < ApplicationRecord
  include TypedDateInput
  include Icanconnect::Claimable

  typed_date_input :service_date

  belongs_to :application
  belongs_to :equipment_item
  has_one_attached :financial_document
  has_many_attached :superseded_financial_documents
  normalizes :vendor_name, with: ->(value) { value.to_s.strip.presence }
  validates :financial_document, :superseded_financial_documents, document: { purpose: :financial_evidence }
  validates :category, inclusion: { in: %w[installation interpretation travel] }
  validates :service_date, presence: true
  validates :amount, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validate :expense_supports_beneficiary

  private

  def expense_supports_beneficiary
    errors.add(:equipment_item, 'must be supplied to this beneficiary') unless equipment_item&.application_id == application_id
    errors.add(:equipment_item, 'must have ICC funding') unless equipment_item&.funding_source == 'icanconnect'
    errors.add(:service_date, 'cannot be in the future') if service_date&.future?
    Icanconnect::Funding.validate!(application, source: funding_source, on: service_date) if application && service_date && funding_qualification_changed?
  rescue ArgumentError => e
    errors.add(:base, e.message)
  end

  def funding_qualification_changed?
    new_record? || will_save_change_to_application_id? || will_save_change_to_equipment_item_id? ||
      will_save_change_to_funding_source? || will_save_change_to_service_date?
  end
end
