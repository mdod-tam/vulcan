# frozen_string_literal: true

module Vendors
  # Run with application writes and storage cleanup paused during the protected-W9 cutover.
  class W9ProtectionBackfill
    OLD_KEY = 'w9_cutover_old_key'
    ROTATED_AT = 'w9_service_key_rotated_at'
    QUARANTINED = 'w9_cutover_quarantined'

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
    end

    def call
      # Active Storage and SQL instrumentation include object keys in ordinary diagnostic logs.
      ActiveStorage.logger.silence(Logger::UNKNOWN) do
        ActiveRecord::Base.logger.silence(Logger::UNKNOWN) do
          protect_vendor_documents
          quarantine_unattributed_staged_uploads
        end
      end
      cursors
    end

    private

    def protect_vendor_documents
      Users::Vendor.find_in_batches(start: @after_vendor_id + 1, batch_size: @batch_size) do |vendors|
        vendors.each do |vendor|
          document_ids(vendor).each { |blob_id| protect_document(vendor, blob_id) }
          @after_vendor_id = vendor.id
        end
        @progress&.call(cursors)
      end
    end

    def document_ids(vendor)
      vendor.with_lock do
        lock_secure_requests(vendor)
        known = vendor.w9_reviews.where.not(reviewed_blob_id: nil).order(:reviewed_blob_id).pluck(:reviewed_blob_id)
        current = vendor.w9_form.blob&.id
        archived = vendor.w9_archive.blobs.map(&:id)
        known.each do |blob_id|
          next if blob_id == current || archived.include?(blob_id)

          blob = ActiveStorage::Blob.lock.find(blob_id)
          W9Document.protect!(blob, vendor: vendor)
          vendor.w9_archive.attach(blob)
          archived << blob_id
        end
        staged = ActiveStorage::Blob.where('metadata::jsonb ->> ? = ?', W9Document::OWNER_KEY, vendor.id.to_s).ids
        ([current] + archived + known + staged).compact.uniq.sort
      end
    end

    def protect_document(vendor, blob_id)
      descendants = with_document_lock(vendor, blob_id) do |blob|
        rotate_service_key(blob) unless blob.metadata[ROTATED_AT].present? || blob.metadata[OLD_KEY].present?
        derivative_ids(blob)
      end
      # The new key and old-key checkpoint have committed before deletion can fail.
      with_document_lock(vendor, blob_id) { |blob| remove_old_service_key(blob) }
      descendants.each { |id| protect_document(vendor, id) }
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
          blob.with_lock do
            next if blob.attachments.exists? || blob.metadata[W9Document::OWNER_KEY].present?

            blob.update!(metadata: blob.metadata.merge(QUARANTINED => true))
          end
          quarantine_document(blob.id) if blob.metadata[QUARANTINED]
          @after_staged_blob_id = blob.id
        end
        @progress&.call(cursors)
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
    end

    def cursors
      { after_vendor_id: @after_vendor_id, after_staged_blob_id: @after_staged_blob_id }
    end
  end
end
