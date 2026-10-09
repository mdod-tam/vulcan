# frozen_string_literal: true

module Vendors
  class ReplaceW9
    # Callers hold the vendor lock before any secure-request or blob lock.
    def self.call(vendor:, file:, attributes: {}, signed_ids: true, min_bytes: nil)
      vendor.with_lock do
        blob = W9Document.resolve!(file, vendor: vendor, signed_ids: signed_ids, min_bytes: min_bytes)
        previous = vendor.w9_form.blob
        if previous && previous.id != blob.id &&
           (vendor.w9_status_approved? || vendor.w9_reviews.exists?(reviewed_blob_id: previous.id))
          W9Document.protect!(previous, vendor: vendor)
          vendor.w9_archive.attach(previous) unless vendor.w9_archive.blobs.exists?(previous.id)
        end
        vendor.assign_attributes(attributes)
        vendor.w9_form = blob
        vendor.w9_status = :pending_review if previous&.id != blob.id
        vendor.save!
        blob
      end
    end
  end
end
