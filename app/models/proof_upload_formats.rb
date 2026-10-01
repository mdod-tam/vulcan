# frozen_string_literal: true

# Canonical allowed types for proof, certification, and W9 document uploads.
module ProofUploadFormats
  ALLOWED_CONTENT_TYPES = %w[
    application/pdf
    image/jpeg
    image/png
    image/heic
    image/heif
    image/tiff
  ].freeze

  ACCEPT_FILE_EXTENSIONS = %w[.pdf .jpg .jpeg .png .heic .heif .tif .tiff].freeze

  # HTML accept list: extensions plus MIME types for mobile browsers (especially HEIC).
  ACCEPT_ATTRIBUTE = (ACCEPT_FILE_EXTENSIONS + ALLOWED_CONTENT_TYPES).join(',').freeze

  HUMAN_LABEL = 'PDF, JPEG, PNG, TIFF, or HEIC/HEIF'

  INVALID_TYPE_MESSAGE = "Invalid file type. Please upload a PDF or an image file (#{HUMAN_LABEL}).".freeze

  PROOF_ATTACHMENT_TYPES = %w[income residency id].freeze

  # Largest income, residency, or ID proof accepted on every intake channel. Inclusive.
  PROOF_MAX_BYTES = 5.megabytes

  def self.allowed_content_types_json
    ALLOWED_CONTENT_TYPES.to_json
  end

  def self.allowed_content_type?(content_type)
    ALLOWED_CONTENT_TYPES.include?(content_type.to_s.split(';').first)
  end

  def self.proof_size_allowed?(byte_size)
    byte_size <= PROOF_MAX_BYTES
  end

  def self.proof_max_megabytes
    PROOF_MAX_BYTES / 1.megabyte
  end
end
