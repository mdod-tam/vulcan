# frozen_string_literal: true

# Weekly check for an income or residency proof that is approved but has no file. It only logs: it changes no proof
# and notifies no one. A proof that is attached and still awaiting review is the normal state, not an inconsistency.
class ProofConsistencyCheckJob < ApplicationJob
  queue_as :low_priority

  CHECKED_DOCUMENTS = [DocumentType::INCOME, DocumentType::RESIDENCY].freeze

  def perform
    Rails.logger.info 'Starting proof consistency check job'

    total = CHECKED_DOCUMENTS.sum { |document_type| log_approved_without_file(document_type.attachment_name) }

    if total.zero?
      Rails.logger.info 'Proof consistency check completed: no approved proof is missing its file'
    else
      Rails.logger.warn "Proof consistency check found #{total} approved proofs without an attached file"
    end
  end

  private

  # @return [Integer] how many applications have this proof approved without a file
  def log_approved_without_file(attachment_name)
    ids = Application.where("#{attachment_name}_status" => :approved).where.missing(:"#{attachment_name}_attachment").pluck(:id)

    ids.each do |id|
      Rails.logger.warn "Inconsistent proof state for application #{id}: #{attachment_name} is approved but has no attached file"
    end
    ids.size
  end
end
