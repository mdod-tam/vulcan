# frozen_string_literal: true

# Model backstop for submitted documents, after UploadedDocument at intake. It checks only the
# blobs attached in this save, from metadata, so routine saves never read files and stored
# documents stay valid when a rule tightens. Provider-generated documents keep their own contract.
#
#   validates :income_proof, document: { purpose: :proof }
class DocumentValidator < ActiveModel::EachValidator
  def validate_each(record, attribute, _value)
    purpose = options.fetch(:purpose)

    new_blobs(record, attribute).each do |blob|
      next if ProofUploadFormats.generated?(blob)

      unless ProofUploadFormats.allowed_content_type?(blob.content_type)
        record.errors.add(attribute, "must be a PDF or an image file (#{ProofUploadFormats::HUMAN_LABEL})")
      end
      record.errors.add(attribute, size_message(purpose)) unless ProofUploadFormats.size_allowed?(purpose, blob.byte_size)
    end
  end

  private

  def new_blobs(record, attribute)
    change = record.attachment_changes[attribute.to_s]
    return Array(change.blobs) if change.respond_to?(:blobs)
    return [change.blob].compact if change.respond_to?(:blob)

    []
  end

  def size_message(purpose)
    megabytes = ProofUploadFormats.max_megabytes(purpose)
    if ProofUploadFormats.max_inclusive?(purpose)
      "is too large. Maximum size allowed is #{megabytes}MB."
    else
      "must be smaller than #{megabytes}MB."
    end
  end
end
