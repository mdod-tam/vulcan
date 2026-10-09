# frozen_string_literal: true

require 'test_helper'

class W9DocumentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @vendor = create(:vendor, :with_w9)
    @admin = create(:admin)
    @blob = @vendor.w9_form.blob
  end

  test 'own current W9 is streamed privately and another vendor is denied' do
    sign_in_as(@vendor)
    get vendor_w9_document_path(@vendor, @blob, disposition: :attachment)
    assert_response :success
    assert_equal @blob.download, response.body
    assert_includes response.headers['Cache-Control'], 'no-store'
    assert_includes response.headers['Cache-Control'], 'private'
    assert_includes response.headers['Content-Disposition'], 'attachment'

    sign_in_as(create(:vendor))
    get vendor_w9_document_path(@vendor, @blob)
    assert_response :not_found
  end

  test 'an administrator can retrieve retained files but the vendor cannot' do
    @blob.with_lock { Vendors::W9Document.protect!(@blob, vendor: @vendor) }
    reference = Vendors::W9Document.reference(@blob, vendor: @vendor)
    Vendors::ReviewW9.new(vendor: @vendor, admin: @admin, attributes: { status: 'approved', reviewed_blob_id: @blob.id }).call
    Vendors::ReplaceW9.call(vendor: @vendor, file: Rack::Test::UploadedFile.new(file_fixture('sample_w9.pdf'), 'application/pdf'))

    sign_in_as(@admin)
    get vendor_w9_document_path(@vendor, @blob)
    assert_response :success
    sign_in_as(@vendor)
    get vendor_w9_document_path(@vendor, @blob)
    assert_response :not_found
    get vendor_w9_document_path(@vendor, @blob, reference: reference)
    assert_response :not_found
  end

  test 'ordinary redirect proxy representation and disk URLs refuse a W9 even to its owner' do
    sign_in_as(@vendor)
    get rails_storage_redirect_path(@blob)
    assert_response :not_found
    get rails_blob_path(@blob)
    assert_response :not_found
    get rails_storage_proxy_path(@blob)
    assert_response :not_found
    variation = ActiveStorage::Variation.encode(resize_to_limit: [100, 100])
    get rails_blob_representation_path(@blob.signed_id, variation, 'w9.png')
    assert_response :not_found
    ActiveStorage::Current.set(url_options: { host: 'www.example.com' }) do
      get URI(@blob.url).request_uri
      assert_response :not_found
    end
  end

  test 'unprotected documents still use ordinary storage URLs' do
    blob = ActiveStorage::Blob.create_and_upload!(io: file_fixture('sample_w9.pdf').open,
                                                  filename: 'unrelated.pdf', content_type: 'application/pdf')
    get rails_storage_redirect_path(blob)
    assert_response :redirect
  end

  test 'public resubmission tokens do not authorize document retrieval' do
    request_form = create(:vendor_secure_request_form, vendor: @vendor)
    get vendor_w9_document_path(@vendor, @blob, token: request_form.public_token_digest)
    assert_redirected_to sign_in_path
  end

  test 'unknown historical document remains labelled unknown instead of showing todays W9' do
    review = create(:w9_review, vendor: @vendor, admin: @admin)
    W9Review.where(id: review.id).update_all(reviewed_blob_id: nil)
    sign_in_as(@admin)
    get admin_vendor_w9_review_path(@vendor, review)
    assert_response :success
    assert_includes response.body, 'Reviewed document unknown.'
    assert_select 'iframe', count: 0
  end
end
