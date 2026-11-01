# frozen_string_literal: true

require 'test_helper'

class W9DocumentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @vendor = create(:vendor, :with_w9)
    @admin = create(:admin)
    @blob = @vendor.w9_form.blob
    mark_document_clean!(@blob, user: @vendor, purpose: :w9, slot: 'w9_form')
  end

  test 'scan clearance is required for current archived and staged W9 downloads' do
    archived, staged = 2.times.map do
      blob = ActiveStorage::Blob.create_and_upload!(io: file_fixture('sample_w9.pdf').open,
                                                    filename: 'w9.pdf', content_type: 'application/pdf')
      mark_document_clean!(blob, user: @vendor, purpose: :w9, slot: 'w9_form')
      Vendors::W9Document.protect!(blob, vendor: @vendor)
    end
    @vendor.w9_archive.attach(archived)
    reference = Vendors::W9Document.reference(staged, vendor: @vendor)
    scans = [@blob, archived, staged].map { |blob| DocumentScan.find_by!(blob_id: blob.id) }
    sign_in_as(@admin)

    %w[pending blocked failed].each do |status|
      scans.each { |scan| scan.update!(status: status) }
      [vendor_w9_document_path(@vendor, @blob), vendor_w9_document_path(@vendor, archived),
       vendor_w9_document_path(@vendor, staged, reference: reference)].each do |path|
        get path
        assert_response :not_found
        assert_empty response.body
        assert_includes response.headers['Cache-Control'], 'no-store'
        get path, headers: { 'Range' => 'bytes=0-10' }
        assert_response :not_found
        assert_empty response.body
      end
    end
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

  test 'W9 downloads support full and partial byte responses' do
    sign_in_as(@vendor)
    path = vendor_w9_document_path(@vendor, @blob)
    get path
    assert_response :success
    assert_equal 'bytes', response.headers['Accept-Ranges']
    assert_equal @blob.byte_size.to_s, response.headers['Content-Length']

    get path, headers: { 'Range' => 'bytes=0-10' }
    assert_response :partial_content
    assert_equal @blob.download.byteslice(0, 11), response.body
    assert_equal "bytes 0-10/#{@blob.byte_size}", response.headers['Content-Range']
    assert_equal '11', response.headers['Content-Length']
    assert_equal 'bytes', response.headers['Accept-Ranges']
    assert_includes response.headers['Cache-Control'], 'no-store'
  end

  test 'an administrator can retrieve retained files but the vendor cannot' do
    @blob.with_lock { Vendors::W9Document.protect!(@blob, vendor: @vendor) }
    reference = Vendors::W9Document.reference(@blob, vendor: @vendor)
    Vendors::ReviewW9.new(vendor: @vendor, admin: @admin, attributes: { status: 'approved', reviewed_blob_id: @blob.id }).call
    replacement = scanned_upload(Rack::Test::UploadedFile.new(file_fixture('sample_w9.pdf'), 'application/pdf'),
                                 user: @vendor, purpose: :w9, slot: 'w9_form')
    Vendors::ReplaceW9.call(vendor: @vendor, file: replacement)

    sign_in_as(@admin)
    get vendor_w9_document_path(@vendor, @blob)
    assert_response :success
    sign_in_as(@vendor)
    get vendor_w9_document_path(@vendor, @blob)
    assert_response :not_found
    get vendor_w9_document_path(@vendor, @blob, reference: reference)
    assert_response :not_found
  end

  test 'ordinary blob and representation URLs refuse a W9 even to its owner' do
    ActiveStorage::VariantWithRecord.any_instance.expects(:processed).never
    ActiveStorage::Preview.any_instance.expects(:processed).never
    sign_in_as(@vendor)
    get rails_blob_path(@blob)
    assert_response :not_found
    get rails_storage_proxy_path(@blob)
    assert_response :not_found
    get document_attachment_path(@vendor.w9_form.attachment)
    assert_response :not_found
    variation = ActiveStorage::Variation.encode(resize_to_limit: [100, 100])
    get rails_blob_representation_proxy_path(@blob.signed_id, variation, 'w9.png')
    assert_response :not_found
  end

  test 'unattached documents have no ordinary storage download audience' do
    blob = ActiveStorage::Blob.create_and_upload!(io: file_fixture('sample_w9.pdf').open,
                                                  filename: 'unrelated.pdf', content_type: 'application/pdf')
    sign_in_as(@admin)
    get rails_blob_path(blob)
    assert_response :not_found
  end

  test 'missing storage and unknown documents have private non-cacheable failures' do
    sign_in_as(@vendor)
    @blob.service.delete(@blob.key)
    get vendor_w9_document_path(@vendor, @blob)
    assert_response :not_found
    assert_empty response.body
    assert_includes response.headers['Cache-Control'], 'no-store'
    assert_includes response.headers['Cache-Control'], 'private'

    get vendor_w9_document_path(@vendor, 0)
    assert_response :not_found
    assert_includes response.headers['Cache-Control'], 'no-store'
    assert_includes response.headers['Cache-Control'], 'private'
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
