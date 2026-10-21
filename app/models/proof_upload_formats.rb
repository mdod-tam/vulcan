# frozen_string_literal: true

# Canonical manual-upload types and purpose-specific limits, including public product PDFs.
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

  # Size limits by document purpose, the same on every manual intake channel.
  PROOF_MAX_BYTES = 5.megabytes
  MAX_SIZES = {
    proof: { bytes: PROOF_MAX_BYTES, inclusive: true },
    certification: { bytes: 10.megabytes, inclusive: true },
    w9: { bytes: 10.megabytes, inclusive: false },
    product_resource: { bytes: 10.megabytes, inclusive: true }
  }.freeze

  # Public secure forms refuse near-empty files; other channels set no minimum.
  SECURE_FORM_MIN_BYTES = 1.kilobyte

  # Provider-generated documents keep their own acceptance contract and skip manual-upload limits.
  GENERATED_SOURCES = %w[docuseal].freeze

  def self.content_types(purpose = nil)
    purpose == :product_resource ? ['application/pdf'] : ALLOWED_CONTENT_TYPES
  end

  def self.allowed_content_types_json(purpose = nil)
    content_types(purpose).to_json
  end

  def self.allowed_content_type?(content_type, purpose: nil)
    content_types(purpose).include?(content_type.to_s.split(';').first)
  end

  def self.max_bytes(purpose)
    MAX_SIZES.fetch(purpose).fetch(:bytes)
  end

  def self.size_allowed?(purpose, byte_size)
    max_inclusive?(purpose) ? byte_size <= max_bytes(purpose) : byte_size < max_bytes(purpose)
  end

  def self.max_inclusive?(purpose)
    MAX_SIZES.fetch(purpose).fetch(:inclusive)
  end

  def self.max_megabytes(purpose)
    max_bytes(purpose) / 1.megabyte
  end

  def self.generated?(blob)
    GENERATED_SOURCES.include?(blob.metadata['source'].to_s)
  end
end
