# frozen_string_literal: true

# The documents an application carries and the names each goes by. Income, residency, and ID follow the
# "<type>_proof" naming; the disability certification does not, so callers ask here instead of building the name.
#
# attachment_name:               the Application attachment, which is also the field name on paper intake forms
# rejection_letter_type:         the PrintQueueItem letter type for a rejection; the certification has no proof-rejection letter
# counts_toward_rejection_limit: a rejection adds to the application's total and can archive it; the certification
#                                has its own rejection flow and does not count
# rejectable_without_file:       a rejection needs no file on the application
DocumentType = Data.define(:key, :attachment_name, :rejection_letter_type, :counts_toward_rejection_limit, :rejectable_without_file)

class DocumentType
  INCOME = new(key: :income, attachment_name: :income_proof, rejection_letter_type: :income_proof_rejected,
               counts_toward_rejection_limit: true, rejectable_without_file: false)
  RESIDENCY = new(key: :residency, attachment_name: :residency_proof, rejection_letter_type: :residency_proof_rejected,
                  counts_toward_rejection_limit: true, rejectable_without_file: false)
  ID = new(key: :id, attachment_name: :id_proof, rejection_letter_type: :id_proof_rejected,
           counts_toward_rejection_limit: true, rejectable_without_file: false)
  DISABILITY_CERTIFICATION = new(key: :disability_certification, attachment_name: :disability_certification,
                                 rejection_letter_type: :other_notification,
                                 counts_toward_rejection_limit: false, rejectable_without_file: true)

  ALL = [INCOME, RESIDENCY, ID, DISABILITY_CERTIFICATION].freeze
  BY_KEY = ALL.index_by { |document_type| document_type.key.to_s }.freeze

  # Raises KeyError for a key that is not a document type.
  def self.fetch(key)
    BY_KEY.fetch(key.to_s)
  end
end
