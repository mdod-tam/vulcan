# frozen_string_literal: true

# Manual documents pass this gate before attachment.
#
# Accepts a multipart upload, an ActiveStorage::Blob, or a signed blob ID when the caller permits one.
# A signed blob ID does not authorize the submitter. Callers enforce request access and domain eligibility.
#
# Existing blobs must be unattached within the cleanup retention window, or attached to this record's same slot.
# Intake and CleanupUnattachedUploadsJob lock the same blob row to prevent a concurrent purge.
# The slot's DocumentValidator declaration selects its purpose and size limit.
# ProofAttachmentValidator inspects content at intake. Routine model saves do not inspect file content.
# Provider-generated documents follow their own acceptance contract.
class UploadedDocument
  class Refused < StandardError
    attr_reader :reason, :purpose

    # Logs and audit metadata use the English refusal.
    def initialize(reason, purpose: nil)
      @reason = reason
      @purpose = purpose
      super(user_message(locale: :en))
    end

    # User messages use the current locale unless the caller supplies one.
    def user_message(locale: I18n.locale)
      UploadedDocument.refusal_message(reason, purpose: purpose, locale: locale)
    end

    # Identifies the document when a form handles several documents.
    def user_message_for(document)
      I18n.t('documents.refused_document', document: document, reason: user_message)
    end
  end

  # Shared refusal wording for server responses and browser validation.
  def self.refusal_message(reason, purpose:, locale: I18n.locale)
    key = reason == :too_large && !ProofUploadFormats.max_inclusive?(purpose) ? :too_large_strict : reason
    I18n.t("documents.refused.#{key}", max_size: purpose && ProofUploadFormats.max_megabytes(purpose), locale: locale)
  end

  # A new upload in `field` takes precedence over the retained reference in `field_signed_id`.
  def self.submitted(params, field)
    params[field].presence || params["#{field}_signed_id"].presence
  end

  # Rebuilds the file shown after a failed submission. A new upload must pass the intake gate.
  # An absent or refused upload falls back to the submitted retained reference when it is restorable.
  def self.retained(params, record:, field:)
    fresh = params[field]
    return resolve!(fresh, record: record, name: field) if fresh.present?

    restorable(params["#{field}_signed_id"], record: record, name: field)
  rescue Refused
    restorable(params["#{field}_signed_id"], record: record, name: field)
  end

  # record and name identify the attachment slot. Use the model class before a record exists.
  # Existing blobs then must be unattached. min_bytes applies only to channels with a minimum size.
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

  # A restorable reference can appear after failure. This read does not lock or inspect content.
  # Submission still calls resolve!.
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

  # Size checks precede content inspection and storage.
  # The blob row precedes the storage write so cleanup can find unattached uploads.
  # This method registers rollback cleanup before either write to handle a caller's later rollback.
  # Rollback and write failures attempt storage deletion. delete_stored logs failed deletion.
  def stored_upload(file)
    check_size(file.size)
    check_content(file)

    io = file.tempfile.tap(&:rewind)
    blob = ActiveStorage::Blob.build_after_unfurling(io: io, filename: file.original_filename,
                                                     content_type: file.content_type)
    ActiveRecord::Base.current_transaction.after_rollback { delete_stored(blob) }
    blob.save!
    begin
      blob.upload_without_unfurling(io.tap(&:rewind))
    rescue StandardError
      delete_stored(blob)
      raise
    end
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
