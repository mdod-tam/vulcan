# frozen_string_literal: true

module VendorPortal
  # Active Storage's direct-upload protocol with a vendor-bound retry reference.
  class W9UploadsController < BaseController
    include ActiveStorage::SetCurrent

    def create
      attributes = params.expect(blob: %i[filename byte_size checksum content_type]).to_h.symbolize_keys
      return head :unprocessable_content unless ProofUploadFormats.size_allowed?(:w9, attributes[:byte_size].to_i)

      current_user.with_lock do
        blob = ActiveStorage::Blob.create_before_direct_upload!(**attributes,
                                                               metadata: { Vendors::W9Document::OWNER_KEY => current_user.id })
        render json: blob.as_json(root: false).merge(
          signed_id: Vendors::W9Document.reference(blob, vendor: current_user),
          direct_upload: { url: blob.service_url_for_direct_upload, headers: blob.service_headers_for_direct_upload }
        )
      end
    end
  end
end
