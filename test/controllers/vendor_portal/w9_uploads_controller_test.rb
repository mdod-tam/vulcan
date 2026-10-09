# frozen_string_literal: true

require 'test_helper'

module VendorPortal
  class W9UploadsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @vendor = create(:vendor)
      sign_in_as(@vendor)
    end

    test 'upload references bind the vendor and retain the original deadline' do
      body = file_fixture('sample_w9.pdf').read
      post vendor_portal_w9_uploads_path, params: { blob: { filename: 'staged.pdf', byte_size: body.bytesize,
                                                            checksum: Digest::MD5.base64digest(body), content_type: 'application/pdf' } }, as: :json
      assert_response :success
      reference = response.parsed_body['signed_id']
      blob = Vendors::W9Document.resolve_reference(reference, vendor: @vendor)
      assert_equal @vendor.id, blob.metadata['w9_vendor_id']
      blob.upload(StringIO.new(body))
      assert_nil Vendors::W9Document.resolve_reference(reference, vendor: create(:vendor))

      get vendor_w9_document_path(@vendor, blob, reference: reference)
      assert_response :success
      get rails_blob_path(blob)
      assert_response :not_found

      travel_to blob.created_at + 7.days + 1.second do
        sign_in_as(@vendor)
        assert_nil Vendors::W9Document.resolve_reference(reference, vendor: @vendor)
        get vendor_w9_document_path(@vendor, blob, reference: reference)
        assert_response :not_found
      end
    end

    test 'generic old or other vendors blob references cannot replace a W9' do
      blob = ActiveStorage::Blob.create_and_upload!(io: file_fixture('sample_w9.pdf').open,
                                                    filename: 'staged.pdf', content_type: 'application/pdf')
      patch vendor_portal_profile_path, params: { users_vendor: { w9_form: blob.signed_id } }
      assert_response :unprocessable_content
      assert_not @vendor.reload.w9_form.attached?
    end
  end
end
