# frozen_string_literal: true

module DocumentScans
  # Only this writer gives the scanner bytes. The snapshot key is never exposed for PUT.
  class Stager
    class SnapshotNotReady < StandardError; end

    ACCOUNT_DAILY_LIMIT = 30
    FORM_DAILY_LIMIT = 10
    GLOBAL_DAILY_LIMIT = 150
    MAX_PENDING = 50
    ALLOCATION_LOCK = 7_481_924_132

    def initialize(input:, purpose:, slot:, user: nil, secure_form: nil, form_context: '', context: {}, continuation: nil, dedup_key: nil) # rubocop:disable Metrics/ParameterLists -- Explicit owner and provider continuation context.
      @input = input
      @purpose = purpose.to_s
      @slot = slot.to_s
      @user = user
      @secure_form = secure_form
      @form_context = form_context.to_s
      @context = context
      @continuation = continuation
      @dedup_key = dedup_key
    end

    def call
      if @dedup_key && (existing = DocumentScan.find_by(dedup_key: @dedup_key))
        return existing_snapshot!(existing)
      end
      raise ArgumentError, 'Invalid scan purpose' unless DocumentScan::PURPOSES.include?(@purpose)
      raise ArgumentError, 'Scan must have exactly one owner' unless [@user, @secure_form, @continuation == 'docuseal' || nil].compact.one?

      with_input do |io, filename|
        validate_input!(io, filename)
        io.rewind
        sha256 = Digest::SHA256.file(io.path).hexdigest
        @blob = ActiveStorage::Blob.build_after_unfurling(io: io, filename: filename, identify: false,
                                                          content_type: Marcel::MimeType.for(io))
        DocumentScan.transaction do
          # Serializes the bounded account/form/global allocation check across dynos.
          DocumentScan.connection.execute("SELECT pg_advisory_xact_lock(#{ALLOCATION_LOCK})")
          check_limits!
          ActiveRecord::Base.current_transaction.after_rollback do
            @blob.service.delete(@blob.key)
          rescue StandardError => e
            Rails.event.notify('document_scan.cleanup_failed', error_class: e.class.name)
          end
          @blob.save!
          @scan = DocumentScan.create!(blob: @blob, user: @user, secure_form: @secure_form, purpose: @purpose, slot: @slot,
                                       form_context: @form_context, sha256: sha256, context: @context,
                                       continuation: @continuation, dedup_key: @dedup_key)
        end
        @blob.upload_without_unfurling(io.tap(&:rewind))
      end
      @scan.update!(next_attempt_at: Time.current)
      @snapshot_ready = true
      enqueue(@scan)
      @scan
    rescue ActiveRecord::RecordNotUnique
      cleanup_snapshot
      existing_snapshot!(DocumentScan.find_by!(dedup_key: @dedup_key))
    rescue StandardError
      cleanup_snapshot unless @snapshot_ready
      raise
    end

    private

    def existing_snapshot!(scan)
      raise SnapshotNotReady, 'Document upload has not finished' if scan.pending? && scan.next_attempt_at.nil? && scan.lease_token.nil? && scan.provider_scan_id.nil?

      enqueue(scan)
      scan
    end

    def with_input
      raise UploadedDocument::Refused.new(:unsupported, purpose: @purpose.to_sym) unless @input.respond_to?(:tempfile) && @input.respond_to?(:original_filename)

      yield @input.tempfile, @input.original_filename
    end

    def validate_input!(io, filename)
      raise UploadedDocument::Refused.new(:too_small, purpose: @purpose.to_sym) unless io.size.positive?
      raise UploadedDocument::Refused.new(:too_large, purpose: @purpose.to_sym) unless ProofUploadFormats.size_allowed?(@purpose.to_sym, io.size)
      raise UploadedDocument::Refused.new(:too_small, purpose: @purpose.to_sym) if @secure_form && io.size < ProofUploadFormats::SECURE_FORM_MIN_BYTES

      file = Struct.new(:tempfile, :original_filename).new(io, filename)
      ProofAttachmentValidator.check_content!(file, allowed_types: ProofUploadFormats.content_types(@purpose.to_sym))
    rescue ProofAttachmentValidator::ValidationError => e
      raise UploadedDocument::Refused.new(e.error_type, purpose: @purpose.to_sym)
    end

    def check_limits!
      recent = DocumentScan.where(created_at: 1.day.ago..)
      owner_count = if @user
                      recent.where(user: @user).count
                    elsif @secure_form
                      recent.where(secure_form: @secure_form).count
                    else
                      0
                    end
      owner_limit = @user ? ACCOUNT_DAILY_LIMIT : FORM_DAILY_LIMIT
      return unless recent.count >= GLOBAL_DAILY_LIMIT || DocumentScan.pending.count >= MAX_PENDING || owner_count >= owner_limit

      Rails.event.notify('document_scan.allocation_limited', owner_type: @user ? 'account' : 'form')
      raise DocumentScan::LimitExceeded, 'Upload limit reached'
    end

    def enqueue(scan)
      if scan.pending?
        DocumentScanJob.perform_later(scan.id)
      elsif scan.clean? && scan.continuation == 'docuseal'
        DocumentSigning::AcceptScannedDocumentJob.perform_later(scan.id)
      end
    end

    def cleanup_snapshot
      return unless @blob&.persisted?

      @scan&.destroy!
      @blob.purge unless @blob.attachments.exists?
    end
  end
end
