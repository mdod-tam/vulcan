# frozen_string_literal: true

# A vendor whose automatic invoicing last failed. Written only by Invoices::GenerationService.
# error_category is a class name, never an error message, so it cannot carry personal data.
class InvoiceGenerationFailure < ApplicationRecord
  belongs_to :vendor, class_name: 'User'

  scope :unresolved, -> { where(resolved_at: nil) }

  def self.record!(vendor_id:, cutoff:, error:)
    failure = unresolved.find_or_initialize_by(vendor_id: vendor_id)
    failure.attempts += 1 if failure.persisted?
    failure.update!(attempted_at: Time.current, cutoff: cutoff, error_category: error.class.name)
  end

  def self.resolve!(vendor_id)
    unresolved.where(vendor_id: vendor_id).update_all(resolved_at: Time.current, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
  end
end
