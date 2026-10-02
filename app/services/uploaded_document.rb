# frozen_string_literal: true

# The one gate a manually submitted document passes before any domain state changes.
#
# Accepts only proven inputs: a multipart upload, an ActiveStorage::Blob, and, where the
# caller allows it, a signed blob ID. A signed ID identifies a blob; it does not authorize
# the submitter, so callers keep their own request and domain checks.
#
# An existing blob is accepted only when it is unattached and inside the cleanup retention
# window, or already attached to this record's same slot. The blob row is locked so the
# decision cannot race CleanupUnattachedUploadsJob, which purges under the same lock.
# The size limit comes from the purpose the model declares for the slot (`validates ..., document:
# { purpose: }`), so callers never restate it. Content is then read once
# by ProofAttachmentValidator, which judges the real type and refuses PDF active content.
# Provider-generated documents do not pass through here.
class UploadedDocument
  class Refused < StandardError
    attr_reader :reason, :purpose

    # The exception text is the English refusal, for logs and audit metadata
    def initialize(reason, purpose: nil)
      @reason = reason
      @purpose = purpose
      super(user_message(locale: :en))
    end

    # The refusal for a person, in the current locale unless one is given
    def user_message(locale: I18n.locale)
      UploadedDocument.refusal_message(reason, purpose: purpose, locale: locale)
    end

    # The refusal prefixed with the document it applies to, for surfaces that handle several
    def user_message_for(document)
      I18n.t('documents.refused_document', document: document, reason: user_message)
    end
  end

  # The one wording for a refusal reason, also given to the browser for its selection-time checks.
  def self.refusal_message(reason, purpose:, locale: I18n.locale)
    key = reason == :too_large && !ProofUploadFormats.max_inclusive?(purpose) ? :too_large_strict : reason
    I18n.t("documents.refused.#{key}", max_size: purpose && ProofUploadFormats.max_megabytes(purpose), locale: locale)
  end

  # What a form submitted for a document field: a new upload in `field` (a multipart file or a
  # direct-upload signed ID) takes precedence over the upload kept from an earlier attempt in
  # `field_signed_id`.
  def self.submitted(params, field)
    params[field].presence || params["#{field}_signed_id"].presence
  end

  # The upload to show again after a failed submission, or nil. A new upload is kept only if it passes
  # the whole gate; otherwise the earlier kept upload stays while it is still restorable.
  def self.retained(params, record:, field:)
    fresh = params[field]
    return resolve!(fresh, record: record, name: field) if fresh.present?

    restorable(params["#{field}_signed_id"], record: record, name: field)
  rescue Refused
    restorable(params["#{field}_signed_id"], record: record, name: field)
  end

  # record and name identify the slot. record may be the model class when no record exists yet;
  # an existing blob is then reusable only while unattached. min_bytes is set only by channels
  # that require a minimum.
  def self.resolve!(input, record:, name:, signed_ids: true, min_bytes: nil)
    new(record: record, name: name, purpose: declared_purpose(record, name), signed_ids: signed_ids,
        min_bytes: min_bytes).resolve!(input)
  end

  def self.declared_purpose(record, name)
    model = record.is_a?(Class) ? record : record.class
    validator = model.validators_on(name.to_sym).find { |each| each.is_a?(DocumentValidator) }
    raise ArgumentError, "#{model.name}##{name} declares no document policy" unless validator

    validator.options.fetch(:purpose)
  end

  # Read-only check for redisplaying a retained upload after a failed submission. It neither
  # locks the blob nor reads its content, so the eventual submission still goes through resolve!.
  def self.restorable(signed_id, record:, name:)
    return unless signed_id.is_a?(String) && signed_id.present?

    blob = ActiveStorage::Blob.find_signed(signed_id)
    gate = new(record: record, name: name, purpose: nil, signed_ids: true, min_bytes: nil)
    blob if blob && gate.reusable?(blob) && blob.service.exist?(blob.key)
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    nil
  end

  def initialize(record:, name:, purpose:, signed_ids:, min_bytes:)
    @record = record.is_a?(Class) ? nil : record
    @name = name.to_s
    @purpose = purpose
    @signed_ids = signed_ids
    @min_bytes = min_bytes
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

  def reusable?(blob)
    !expired_unattached?(blob) && !attached_elsewhere?(blob)
  end

  private

  def multipart_file?(input)
    input.respond_to?(:original_filename) && input.respond_to?(:tempfile)
  end

  # The request supplies the size, so limits are checked before the file is read or stored.
  # Outside a transaction the blob row persists unattached, where CleanupUnattachedUploadsJob finds
  # it. Inside a caller's transaction a rollback removes the row, so the stored object goes with it.
  def stored_upload(file)
    check_size(file.size)
    check_content(file)

    blob = ActiveStorage::Blob.create_and_upload!(
      io: file.tempfile.tap(&:rewind),
      filename: file.original_filename,
      content_type: file.content_type
    )
    ActiveRecord::Base.current_transaction.after_rollback { delete_stored(blob) }
    blob
  end

  def delete_stored(blob)
    blob.service.delete(blob.key)
  rescue StandardError => e
    Rails.logger.error("UploadedDocument could not delete rolled-back upload #{blob.key}: #{e.message}")
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
    check_content(blob)
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
    refuse(:too_large) unless ProofUploadFormats.size_allowed?(@purpose, byte_size.to_i)
    refuse(:too_small) if @min_bytes && byte_size.to_i < @min_bytes
  end

  def check_content(file_or_blob)
    ProofAttachmentValidator.check_content!(file_or_blob)
  rescue ProofAttachmentValidator::ValidationError => e
    refuse(e.error_type)
  end

  def refuse(reason)
    raise Refused.new(reason, purpose: @purpose)
  end
end
