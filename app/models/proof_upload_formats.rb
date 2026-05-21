# frozen_string_literal: true

# Canonical allowed types for proof, certification, and W9 document uploads.
module ProofUploadFormats
  ALLOWED_CONTENT_TYPES = %w[
    application/pdf
    image/jpeg
    image/png
    image/heic
    image/heif
  ].freeze

  ACCEPT_FILE_EXTENSIONS = %w[.pdf .jpg .jpeg .png .heic .heif].freeze

  # HTML accept list: extensions plus MIME types for mobile browsers (especially HEIC).
  ACCEPT_ATTRIBUTE = (ACCEPT_FILE_EXTENSIONS + ALLOWED_CONTENT_TYPES).join(',').freeze

  HUMAN_LABEL = 'PDF, JPEG, PNG, or HEIC/HEIF'

  INVALID_TYPE_MESSAGE = "Invalid file type. Please upload a PDF or an image file (#{HUMAN_LABEL}).".freeze

  PROOF_ATTACHMENT_TYPES = %w[income residency id].freeze

  def self.allowed_content_types_json
    ALLOWED_CONTENT_TYPES.to_json
  end
end
