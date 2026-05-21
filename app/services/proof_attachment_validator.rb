# frozen_string_literal: true

class ProofAttachmentValidator
  ALLOWED_MIME_TYPES = ProofUploadFormats::ALLOWED_CONTENT_TYPES

  MAX_FILE_SIZE = 10.megabytes
  MIN_FILE_SIZE = 1.kilobyte

  class ValidationError < StandardError
    attr_reader :error_type

    def initialize(error_type, message)
      @error_type = error_type
      super(message)
    end
  end

  def self.validate!(attachment, **)
    new(**).validate!(attachment)
  end

  def initialize(allowed_mime_types: ALLOWED_MIME_TYPES, max_file_size: MAX_FILE_SIZE, min_file_size: MIN_FILE_SIZE)
    @allowed_mime_types = allowed_mime_types
    @max_file_size = max_file_size
    @min_file_size = min_file_size
  end

  def validate!(attachment)
    @attachment_content = nil
    @detected_mime_type = nil

    validate(attachment)
  rescue StandardError => e
    raise e if e.is_a?(ValidationError)

    Rails.logger.error("Unexpected error in proof validation: #{e.message}")
    raise ValidationError.new(:unknown_error, 'An unexpected error occurred during validation')
  end

  def validate(attachment)
    validation_error(:no_attachment, 'No attachment provided') if attachment.nil?

    attachment_size = attachment_size(attachment)

    if attachment_size < @min_file_size
      validation_error(:file_too_small,
                       "File is too small (minimum #{@min_file_size} bytes)")
    end
    if attachment_size > @max_file_size
      validation_error(:file_too_large,
                       "File is too large (maximum #{@max_file_size} bytes)")
    end
    validation_error(:invalid_type, 'File type not allowed') unless valid_mime_type?(attachment)

    if potentially_malicious?(attachment)
      validation_error(:suspicious_content,
                       'File contains suspicious content')
    end

    true
  end

  private

  def attachment_size(attachment)
    return attachment.byte_size if attachment.respond_to?(:byte_size)
    return attachment.size if attachment.respond_to?(:size)
    return attachment.decoded.bytesize if attachment.respond_to?(:decoded)
    return attachment.body.decoded.bytesize if attachment.respond_to?(:body) && attachment.body.respond_to?(:decoded)

    attachment_content(attachment).bytesize
  end

  def validation_error(type, message)
    raise ValidationError.new(type, message)
  end

  def valid_mime_type?(attachment)
    @allowed_mime_types.include?(detected_mime_type(attachment))
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
    @detected_mime_type ||= begin
      content = attachment_content(attachment)
      Marcel::MimeType.for(
        StringIO.new(content),
        name: attachment_filename(attachment),
        declared_type: declared_content_type(attachment)
      )
    end
  end

  def attachment_content(attachment)
    @attachment_content ||= if attachment.respond_to?(:download)
                              attachment.download.to_s
                            elsif attachment.respond_to?(:tempfile)
                              read_io(attachment.tempfile)
                            elsif attachment.respond_to?(:decoded)
                              attachment.decoded.to_s
                            elsif attachment.respond_to?(:body) && attachment.body.respond_to?(:decoded)
                              attachment.body.decoded.to_s
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
