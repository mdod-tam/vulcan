# frozen_string_literal: true

module Vendors
  # Run with application writes and storage cleanup paused during the protected-W9 cutover.
  class W9ProtectionBackfill
    OLD_KEY = 'w9_cutover_old_key'
    ROTATED_AT = 'w9_service_key_rotated_at'
    QUARANTINED = 'w9_cutover_quarantined'

    class DocumentFailure < StandardError
      attr_reader :vendor_id, :blob_id, :error_class

      def initialize(vendor_id:, blob_id:, error:)
        @vendor_id = vendor_id
        @blob_id = blob_id
        @error_class = error.class.name
        super("vendor_id=#{vendor_id || 'none'} blob_id=#{blob_id || 'unknown'} error=#{error_class}")
      end
    end

    class Incomplete < StandardError
      attr_reader :failures, :cursors

      def initialize(failures:, cursors:)
        @failures = failures
        @cursors = cursors
        super("#{failures.length} document protection failures; application access must remain paused")
      end
    end

    def self.call(cutover_at:, after_vendor_id: 0, after_staged_blob_id: 0, batch_size: 100, &progress)
      raise ArgumentError, 'cutover_at must be in the past' if cutover_at.future?
      raise ArgumentError, 'batch_size must be positive' unless batch_size.positive?

      new(cutover_at, after_vendor_id, after_staged_blob_id, batch_size, progress).call
    end

    def initialize(cutover_at, after_vendor_id, after_staged_blob_id, batch_size, progress)
      @cutover_at = cutover_at
      @after_vendor_id = after_vendor_id
      @after_staged_blob_id = after_staged_blob_id
      @batch_size = batch_size
      @progress = progress
      @failures = []
    end

    def call
      # Active Storage and SQL instrumentation include object keys in ordinary diagnostic logs.
      ActiveStorage.logger.silence(Logger::UNKNOWN) do
        ActiveRecord::Base.logger.silence(Logger::UNKNOWN) do
          protect_vendor_documents
          quarantine_unattributed_staged_uploads
        end
      end
      raise Incomplete.new(failures: @failures, cursors: cursors) if @failures.any?

      cursors
    end

    private

    def protect_vendor_documents
      Users::Vendor.find_in_batches(start: @after_vendor_id + 1, batch_size: @batch_size) do |vendors|
        vendors.each do |vendor|
          completed = attempt(vendor_id: vendor.id) do
            document_ids(vendor).map { |blob_id| attempt(vendor_id: vendor.id, blob_id: blob_id) { protect_document(vendor, blob_id) } }.all?
          end
          @vendor_cursor_blocked ||= !completed
          @after_vendor_id = vendor.id unless @vendor_cursor_blocked
        end
        report_progress
      end
    end

    def document_ids(vendor)
      vendor.with_lock do
        lock_secure_requests(vendor)
        known = vendor.w9_reviews.where.not(reviewed_blob_id: nil).order(:reviewed_blob_id).pluck(:reviewed_blob_id)
        current = vendor.w9_form.blob&.id
        archived = vendor.w9_archive.blobs.map(&:id)
        staged = ActiveStorage::Blob.where('metadata::jsonb ->> ? = ?', W9Document::OWNER_KEY, vendor.id.to_s).ids
        ([current] + archived + known + staged).compact.uniq.sort
      end
    end

    def protect_document(vendor, blob_id)
      descendants = with_document_lock(vendor, blob_id) do |blob|
        retain_reviewed_document(vendor, blob)
        rotate_service_key(blob) unless blob.metadata[ROTATED_AT].present? || blob.metadata[OLD_KEY].present?
        derivative_ids(blob)
      end
      # The new key and old-key checkpoint have committed before deletion can fail.
      with_document_lock(vendor, blob_id) { |blob| remove_old_service_key(blob) }
      descendants.each { |id| protect_document(vendor, id) }
    rescue DocumentFailure
      raise
    rescue StandardError => e
      raise DocumentFailure.new(vendor_id: vendor.id, blob_id: blob_id, error: e)
    end

    def retain_reviewed_document(vendor, blob)
      return if vendor.w9_form.blob&.id == blob.id || vendor.w9_archive.blobs.exists?(blob.id)
      return unless vendor.w9_reviews.exists?(reviewed_blob_id: blob.id)

      raise ActiveRecord::RecordInvalid, vendor unless vendor.w9_archive.attach(blob)
    end

    def with_document_lock(vendor, blob_id)
      vendor.with_lock do
        lock_secure_requests(vendor)
        blob = ActiveStorage::Blob.lock.find(blob_id)
        W9Document.protect!(blob, vendor: vendor)
        yield blob
      end
    end

    def lock_secure_requests(vendor)
      vendor.vendor_secure_request_forms.order(:id).lock.load
    end

    def rotate_service_key(blob)
      old_key = blob.key
      new_key = ActiveStorage::Blob.generate_unique_secure_token
      blob.open do |io|
        blob.service.upload(new_key, io, checksum: blob.checksum, filename: blob.filename,
                                         content_type: blob.content_type, disposition: :attachment)
      end
      # Storage cutover intentionally changes Active Storage's managed key without replacing its
      # blob identity, created_at, review references, or seven-day retry deadline.
      blob.update_columns(key: new_key, metadata: blob.metadata.merge(OLD_KEY => old_key)) # rubocop:disable Rails/SkipsModelValidations
    end

    def remove_old_service_key(blob)
      old_key = blob.metadata[OLD_KEY]
      return unless old_key

      blob.service.delete(old_key)
      blob.service.delete_prefixed("variants/#{old_key}/")
      blob.update!(metadata: blob.metadata.except(OLD_KEY).merge(ROTATED_AT => Time.current.iso8601))
    end

    def derivative_ids(blob)
      preview = blob.preview_image.blob&.id
      variants = blob.variant_records.includes(image_attachment: :blob).filter_map { |record| record.image.blob&.id }
      ([preview] + variants).compact.uniq.sort
    end

    def quarantine_unattributed_staged_uploads
      known_reviews = W9Review.where.not(reviewed_blob_id: nil).select(:reviewed_blob_id)
      ActiveStorage::Blob.unattached.where(created_at: ...@cutover_at)
                         .where('metadata::jsonb ->> ? IS NULL', W9Document::OWNER_KEY)
                         .where.not(id: known_reviews)
                         .find_in_batches(start: @after_staged_blob_id + 1, batch_size: @batch_size) do |blobs|
        blobs.each do |blob|
          completed = attempt(blob_id: blob.id) do
            blob.with_lock do
              next if blob.attachments.exists? || blob.metadata[W9Document::OWNER_KEY].present?

              blob.update!(metadata: blob.metadata.merge(QUARANTINED => true))
            end
            quarantine_document(blob.id) if blob.metadata[QUARANTINED]
          end
          @staged_cursor_blocked ||= !completed
          @after_staged_blob_id = blob.id unless @staged_cursor_blocked
        end
        report_progress
      end
    end

    def quarantine_document(blob_id)
      blob = ActiveStorage::Blob.find(blob_id)
      descendants = blob.with_lock do
        blob.update!(metadata: blob.metadata.merge(QUARANTINED => true))
        rotate_service_key(blob) unless blob.metadata[ROTATED_AT].present? || blob.metadata[OLD_KEY].present?
        derivative_ids(blob)
      end
      blob.with_lock { remove_old_service_key(blob) }
      descendants.each { |id| quarantine_document(id) }
    rescue DocumentFailure
      raise
    rescue StandardError => e
      raise DocumentFailure.new(vendor_id: nil, blob_id: blob_id, error: e)
    end

    def attempt(vendor_id: nil, blob_id: nil)
      result = yield
      result != false
    rescue StandardError => e
      failure = e.is_a?(DocumentFailure) ? e : DocumentFailure.new(vendor_id: vendor_id, blob_id: blob_id, error: e)
      @failures << { vendor_id: failure.vendor_id, blob_id: failure.blob_id, error_class: failure.error_class }
      false
    end

    def report_progress
      @progress&.call(cursors.merge(failures: @failures.dup))
    end

    def cursors
      { after_vendor_id: @after_vendor_id, after_staged_blob_id: @after_staged_blob_id }
    end
  end
end
