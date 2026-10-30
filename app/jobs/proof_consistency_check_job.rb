# frozen_string_literal: true

# Weekly check for an income or residency proof that is approved but has no file. It only logs: it changes no proof
# and notifies no one. A proof that is attached and still awaiting review is the normal state, not an inconsistency.
class ProofConsistencyCheckJob < ApplicationJob
  queue_as :low_priority

  def perform
    Rails.logger.info 'Starting proof consistency check job'

    income = Application.income_proof_status_approved.where.missing(:income_proof_attachment)
    residency = Application.residency_proof_status_approved.where.missing(:residency_proof_attachment)
    total = log_approved_without_file(income, DocumentType::INCOME.attachment_name) +
            log_approved_without_file(residency, DocumentType::RESIDENCY.attachment_name)

    if total.zero?
      Rails.logger.info 'Proof consistency check completed: no approved proof is missing its file'
    else
      Rails.logger.warn "Proof consistency check found #{total} approved proofs without an attached file"
    end
  end

  private

  # @return [Integer] how many applications have this proof approved without a file
  def log_approved_without_file(applications, attachment_name)
    ids = applications.pluck(:id)

    ids.each do |id|
      Rails.logger.warn "Inconsistent proof state for application #{id}: #{attachment_name} is approved but has no attached file"
    end
    ids.size
  end
end
