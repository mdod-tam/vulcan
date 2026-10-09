# frozen_string_literal: true

module Vendors
  # Owns protection and retry references for current, reviewed, and staged W9s.
  class W9Document
    OWNER_KEY = 'w9_vendor_id'

    def self.protected?(blob)
      return false unless blob
      return true if blob.metadata[OWNER_KEY].present? || blob.metadata['w9_cutover_quarantined']
      return true if blob.attachments.exists?(name: %w[w9_form w9_archive])
      return true if W9Review.exists?(reviewed_blob_id: blob.id)

      blob.attachments.any? do |attachment|
        parent = attachment.record
        (parent.is_a?(ActiveStorage::Blob) && protected?(parent)) ||
          (parent.is_a?(ActiveStorage::VariantRecord) && protected?(parent.blob))
      end
    end

    def self.protected_key?(key)
      blob = ActiveStorage::Blob.find_by(key: key) || ActiveStorage::Blob.where('metadata::jsonb ->> ? = ?', 'w9_cutover_old_key', key).first
      return protected?(blob) if blob
      return false unless key.start_with?('variants/')

      parent_key = key.split('/')[1]
      parent = ActiveStorage::Blob.find_by(key: parent_key) || ActiveStorage::Blob.where('metadata::jsonb ->> ? = ?', 'w9_cutover_old_key', parent_key).first
      protected?(parent)
    end

    def self.protect!(blob, vendor:)
      owner = blob.metadata[OWNER_KEY]
      raise UploadedDocument::Refused.new(:attached_elsewhere, purpose: :w9) if owner && owner.to_i != vendor.id

      blob.update!(metadata: blob.metadata.merge(OWNER_KEY => vendor.id))
      blob
    end

    def self.reference(blob, vendor:)
      verifier.generate({ 'blob_id' => blob.id, 'vendor_id' => vendor.id },
                        expires_at: blob.created_at + CleanupUnattachedUploadsJob::RETENTION)
    end

    def self.resolve_reference(reference, vendor:)
      payload = verifier.verified(reference)
      return unless payload && payload['vendor_id'] == vendor.id

      blob = ActiveStorage::Blob.find_by(id: payload['blob_id'])
      blob if blob && blob.metadata[OWNER_KEY].to_i == vendor.id
    end

    def self.retained(params, vendor:)
      fresh = UploadedDocument.submitted(params, 'w9_form')
      resolve!(fresh, vendor: vendor) if fresh.present?
    rescue UploadedDocument::Refused
      restorable(params['w9_form_signed_id'], vendor: vendor)
    end

    def self.restorable(reference, vendor:)
      blob = resolve_reference(reference, vendor: vendor)
      return unless blob && blob.created_at > CleanupUnattachedUploadsJob::RETENTION.ago && blob.service.exist?(blob.key)

      current = vendor.w9_form.blob
      blob if !blob.attachments.exists? || current&.id == blob.id
    end

    def self.resolve!(input, vendor:, signed_ids: true, min_bytes: nil)
      if input.is_a?(String)
        raise UploadedDocument::Refused.new(:unavailable, purpose: :w9) unless signed_ids

        input = resolve_reference(input, vendor: vendor) || raise(UploadedDocument::Refused.new(:unavailable, purpose: :w9))
      end
      blob = UploadedDocument.resolve!(input, record: vendor, name: 'w9_form', signed_ids: false, min_bytes: min_bytes)
      protect!(blob, vendor: vendor)
    end

    def self.verifier = Rails.application.message_verifier('vendor-w9-upload')
    private_class_method :verifier
  end
end
