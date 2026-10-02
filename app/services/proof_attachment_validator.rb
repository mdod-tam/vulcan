# frozen_string_literal: true

# Content inspection for submitted documents. UploadedDocument calls it on every manual
# intake path after size checks pass, so a file is read at most once at intake and never
# on routine saves. The PDF substring checks flag active content; they are not a malware scan.
class ProofAttachmentValidator
  ALLOWED_MIME_TYPES = ProofUploadFormats::ALLOWED_CONTENT_TYPES

  class ValidationError < StandardError
    attr_reader :error_type

    def initialize(error_type, message)
      @error_type = error_type
      super(message)
    end
  end

  def self.check_content!(attachment)
    new.check_content!(attachment)
  end

  # Raises ValidationError with :invalid_type, :suspicious_content, or :unreadable
  def check_content!(attachment)
    @attachment_content = nil
    @detected_mime_type = nil

    validation_error(:invalid_type, 'File type not allowed') unless valid_mime_type?(attachment)
    validation_error(:suspicious_content, 'File contains suspicious content') if potentially_malicious?(attachment)

    true
  rescue ValidationError
    raise
  rescue StandardError => e
    Rails.logger.error("Unexpected error in document content inspection: #{e.message}")
    raise ValidationError.new(:unreadable, 'The file could not be read')
  end

  private

  def validation_error(type, message)
    raise ValidationError.new(type, message)
  end

  def valid_mime_type?(attachment)
    ALLOWED_MIME_TYPES.include?(detected_mime_type(attachment))
  end

  def potentially_malicious?(attachment)
    filename = attachment_filename(attachment).downcase
    return true if suspicious_filename?(filename)
    return true if detected_mime_type(attachment) == 'application/pdf' && pdf_malicious?(attachment)

    false
  end

  def suspicious_filename?(filename)
    filename.include?('..') ||
      filename.include?('/') ||
      filename.include?('\\') ||
      filename =~ /\.(exe|sh|bat|cmd|vbs|js)$/i
  end

  def pdf_malicious?(attachment)
    content = attachment_content(attachment)

    content.include?('/JS') ||
      content.include?('/JavaScript') ||
      content.include?('/Launch') ||
      content.include?('/SubmitForm') ||
      content.include?('/RichMedia')
  end

  def detected_mime_type(attachment)
    @detected_mime_type ||= Marcel::MimeType.for(
      StringIO.new(attachment_content(attachment)),
      name: attachment_filename(attachment),
      declared_type: declared_content_type(attachment)
    )
  end

  def attachment_content(attachment)
    @attachment_content ||= if attachment.respond_to?(:download)
                              attachment.download.to_s
                            elsif attachment.respond_to?(:tempfile)
                              read_io(attachment.tempfile)
                            elsif attachment.respond_to?(:read)
                              read_io(attachment)
                            else
                              attachment.to_s
                            end
  end

  def read_io(io)
    io.rewind if io.respond_to?(:rewind)
    io.read.to_s
  ensure
    io.rewind if io.respond_to?(:rewind)
  end

  def attachment_filename(attachment)
    if attachment.respond_to?(:original_filename)
      attachment.original_filename.to_s
    elsif attachment.respond_to?(:filename)
      attachment.filename.to_s
    else
      ''
    end
  end

  def declared_content_type(attachment)
    return unless attachment.respond_to?(:content_type)

    attachment.content_type.to_s.split(';').first
  end
end
