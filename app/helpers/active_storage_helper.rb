# frozen_string_literal: true

module ActiveStorageHelper
  # Page controls resolve the current attachment through the authenticated reader.
  def document_download_path(document, **)
    attachment = document.is_a?(ActiveStorage::Attachment) ? document : document.attachment
    document_attachment_path(attachment, **)
  end

  # The attachment's filename, or nil when nothing is attached.
  def safe_attachment_filename(attachment)
    return nil unless attachment.attached?

    attachment.filename.to_s
  end

  # The attachment's byte size, or nil when nothing is attached.
  def safe_attachment_byte_size(attachment)
    return nil unless attachment.attached?

    attachment.byte_size
  end

  # The attachment's content type, or nil when nothing is attached.
  def safe_attachment_content_type(attachment)
    return nil unless attachment.attached?

    attachment.content_type
  end

  # Whether the attachment's content type is one of the allowed proof upload types.
  def safe_attachment_previewable?(attachment)
    return false unless attachment.attached?

    ProofUploadFormats::ALLOWED_CONTENT_TYPES.include?(safe_attachment_content_type(attachment))
  end

  # A URL for the attachment's variant when options are given, otherwise its blob URL. Returns nil when
  # nothing is attached or the URL cannot be generated.
  def safe_attachment_representation_url(attachment, **options)
    return nil unless attachment.attached?

    if options.present?
      Rails.application.routes.url_helpers.rails_representation_url(attachment.representation(options))
    else
      Rails.application.routes.url_helpers.rails_blob_url(attachment)
    end
  rescue StandardError => e
    Rails.logger.error "Error generating representation URL: #{e.class.name}"
    nil
  end
end
