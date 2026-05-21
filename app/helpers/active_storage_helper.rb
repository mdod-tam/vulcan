# frozen_string_literal: true

module ActiveStorageHelper
  # Safely extracts filename from an attachment without triggering unnecessary eager loading
  # of ActiveStorage::Blob association that aren't needed
  def safe_attachment_filename(attachment)
    return nil unless attachment.attached?

    # Use direct attributes when possible instead of accessing through association
    # which would trigger unnecessary eager loading
    attachment.filename.to_s
  end

  # Safely gets byte size from an attachment without triggering unnecessary eager loading
  def safe_attachment_byte_size(attachment)
    return nil unless attachment.attached?

    # Use direct attributes when possible instead of accessing through association
    attachment.byte_size
  end

  # Safely gets content type from an attachment without triggering unnecessary eager loading
  def safe_attachment_content_type(attachment)
    return nil unless attachment.attached?

    # Access content_type directly to avoid loading blob associations
    attachment.content_type
  end

  # Safely check if an attachment has a preview image without triggering unnecessary eager loading
  def safe_attachment_previewable?(attachment)
    return false unless attachment.attached?

    ProofUploadFormats::ALLOWED_CONTENT_TYPES.include?(safe_attachment_content_type(attachment))
  end

  # Safely get representation URL without triggering eager loading of variant_records
  def safe_attachment_representation_url(attachment, **options)
    return nil unless attachment.attached?

    # Use the base URL without accessing variant_records association
    if options.present?
      Rails.application.routes.url_helpers.rails_representation_url(attachment.representation(options))
    else
      Rails.application.routes.url_helpers.rails_blob_url(attachment)
    end
  rescue StandardError => e
    Rails.logger.error "Error generating representation URL: #{e.message}"
    nil
  end
end
