# frozen_string_literal: true

# Resolves a submitted document to a stored blob before any domain state changes.
#
# Accepts only proven inputs: a multipart upload, an ActiveStorage::Blob, and, where the
# caller allows it, a signed blob ID. A signed ID identifies a blob; it does not authorize
# the submitter, so callers keep their own request and domain checks.
#
# An existing blob is accepted only when it is unattached and inside the cleanup retention
# window, or already attached to this record's same slot. The blob row is locked so the
# decision cannot race CleanupUnattachedUploadsJob, which purges under the same lock.
# Types are judged by the identified content type, which Active Storage reads from the file.
class UploadedDocument
  class Refused < StandardError
    attr_reader :reason

    def initialize(reason, message)
      @reason = reason
      super(message)
    end
  end

  MESSAGES = {
    missing: 'No file was provided',
    unsupported: 'The upload could not be read',
    unavailable: 'The uploaded file is no longer available',
    expired: 'The uploaded file has expired',
    attached_elsewhere: 'The uploaded file is already attached elsewhere',
    invalid_type: ProofUploadFormats::INVALID_TYPE_MESSAGE,
    too_large: 'The file is too large'
  }.freeze

  # record and name identify the one attachment slot an already attached blob may be reused for.
  # max_bytes is inclusive; nil applies no size limit.
  def self.resolve!(input, record:, name:, max_bytes: nil, signed_ids: true)
    new(record: record, name: name, max_bytes: max_bytes, signed_ids: signed_ids).resolve!(input)
  end

  def initialize(record:, name:, max_bytes:, signed_ids:)
    @record = record
    @name = name.to_s
    @max_bytes = max_bytes
    @signed_ids = signed_ids
  end

  def resolve!(input)
    if input.is_a?(ActiveStorage::Blob)
      checked_blob(input)
    elsif multipart_file?(input)
      stored_upload(input)
    elsif input.is_a?(String) && input.present?
      refuse(:unsupported) unless @signed_ids
      checked_blob(find_signed_blob(input))
    elsif input.blank?
      refuse(:missing)
    else
      refuse(:unsupported)
    end
  end

  private

  def multipart_file?(input)
    input.respond_to?(:original_filename) && input.respond_to?(:tempfile)
  end

  # Size and type come from the request, so they are checked before anything is stored
  def stored_upload(file)
    check_size(file.size)
    check_type(file.content_type)

    ActiveStorage::Blob.create_and_upload!(
      io: file.tempfile.tap(&:rewind),
      filename: file.original_filename,
      content_type: file.content_type
    )
  end

  def find_signed_blob(signed_id)
    ActiveStorage::Blob.find_signed!(signed_id)
  rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveRecord::RecordNotFound
    refuse(:unavailable)
  end

  def checked_blob(blob)
    blob.lock!
    refuse(:expired) if expired_unattached?(blob)
    refuse(:attached_elsewhere) if attached_elsewhere?(blob)
    check_size(blob.byte_size)
    refuse(:unavailable) unless blob.service.exist?(blob.key)
    # A direct upload's content type is the browser's claim until Active Storage reads the file
    blob.identify unless blob.identified?
    check_type(blob.content_type)
    blob
  rescue ActiveRecord::RecordNotFound
    refuse(:unavailable)
  end

  def expired_unattached?(blob)
    !blob.attachments.exists? && blob.created_at <= CleanupUnattachedUploadsJob::RETENTION.ago
  end

  def attached_elsewhere?(blob)
    permitted = blob.attachments.where(record: @record, name: @name)
    blob.attachments.where.not(id: permitted.select(:id)).exists?
  end

  def check_size(byte_size)
    refuse(:too_large) if @max_bytes && byte_size.to_i > @max_bytes
  end

  def check_type(content_type)
    refuse(:invalid_type) unless ProofUploadFormats.allowed_content_type?(content_type)
  end

  def refuse(reason)
    raise Refused.new(reason, MESSAGES.fetch(reason))
  end
end
