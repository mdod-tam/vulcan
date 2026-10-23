# frozen_string_literal: true

require 'test_helper'

class AttachmentDownloadsControllerTest < ActionDispatch::IntegrationTest
  setup do
    ensure_system_audit_actor!
    @application = create(:application, :draft)
    @application.income_proof.attach(io: file_fixture('sample.png').open, filename: 'proof.png', content_type: 'image/png')
    @blob = @application.income_proof.blob
    mark_document_clean!(@blob, user: @application.user)
  end

  test 'unscanned or blocked bytes cannot stream or create a representation' do
    authenticate(@application.user)
    variation = ActiveStorage::Variation.encode(resize_to_limit: [10, 10])
    paths = [rails_blob_path(@blob), rails_blob_representation_proxy_path(@blob.signed_id, variation, 'proof.png')]
    scan = DocumentScan.find_by!(blob_id: @blob.id)
    ActiveStorage::VariantWithRecord.any_instance.expects(:processed).never
    ActiveStorage::Preview.any_instance.expects(:processed).never
    %w[pending blocked failed].each do |status|
      scan.update!(status: status)
      paths.each do |path|
        assert_no_difference ['ActiveStorage::VariantRecord.count', 'ActiveStorage::Blob.count'] do
          get path
        end
        assert_response :not_found
        assert_empty response.body
        assert_private_response
      end
      get rails_blob_path(@blob), headers: { 'Range' => 'bytes=0-10' }
      assert_response :not_found
      assert_empty response.body
    end

    scan.destroy!
    get rails_blob_path(@blob)
    assert_response :not_found
  end

  test 'blob URLs require a current sign-in and check the owner' do
    authenticate(@application.user)
    get rails_blob_path(@blob)
    assert_response :success
    assert_equal @blob.download, response.body
    assert_private_response

    authenticate(create(:constituent))
    get rails_blob_path(@blob)
    assert_response :not_found
    assert_private_response

    reset!
    clear_test_identity
    get rails_blob_path(@blob)
    assert_redirected_to sign_in_path
    assert_private_response
  end

  test 'default blob and representation URLs expire while the owner session remains valid' do
    freeze_time do
      authenticate(@application.user)
      variant, = prepared_variant
      paths = [rails_blob_path(@blob), rails_representation_path(variant)]
      assert_equal 15.minutes, ActiveStorage.urls_expire_in

      paths.each do |path|
        get path
        assert_response :success
      end

      travel 15.minutes - 1.second
      paths.each do |path|
        get path
        assert_response :success
      end

      travel 1.second
      paths.each do |path|
        get path
        assert_response :not_found
        assert_private_response
      end
      assert cookies[:session_token].present?, 'URL expiry must not depend on signing the owner out'

      [rails_blob_path(@blob), rails_representation_path(variant)].each do |path|
        get path
        assert_response :success
      end
    end
  end

  test 'the managing guardian can read proofs and loses access when management changes' do
    guardian = create(:constituent)
    create(:guardian_relationship, guardian_user: guardian, dependent_user: @application.user)
    @application.update!(managing_guardian: guardian)
    authenticate(guardian)
    get rails_blob_path(@blob)
    assert_response :success

    @application.update!(managing_guardian: nil)
    get rails_blob_path(@blob)
    assert_response :not_found
  end

  test 'administrators can read proofs and certifications while constituent access stays limited to proof slots' do
    @application.medical_certification.attach(io: file_fixture('medical_certification_valid.pdf').open,
                                              filename: 'certification.pdf', content_type: 'application/pdf')
    certification = @application.medical_certification.blob
    mark_document_clean!(certification, user: @application.user, purpose: :certification, slot: 'medical_certification')
    authenticate(@application.user)
    get rails_blob_path(certification)
    assert_response :not_found

    authenticate(create(:admin))
    [@blob, certification].each do |blob|
      get rails_blob_path(blob)
      assert_response :success
      assert_equal blob.download, response.body
      assert_private_response
    end
  end

  test 'sign-out and server session revocation invalidate a previously working document URL' do
    user = @application.user
    authenticate(user)
    get rails_blob_path(@blob)
    assert_response :success
    user.sessions.destroy_all
    get rails_blob_path(@blob)
    assert_redirected_to sign_in_path

    authenticate(user)
    delete sign_out_path
    get rails_blob_path(@blob)
    assert_redirected_to sign_in_path
  end

  test 'document retrieval inherits password-change and required MFA enrollment gates' do
    user = @application.user
    authenticate(user)
    user.update!(force_password_change: true)
    get rails_blob_path(@blob)
    assert_redirected_to edit_password_path

    admin = create(:admin)
    reset!
    clear_test_identity
    post sign_in_path, params: { email: admin.email, password: 'password1234' }
    get rails_blob_path(@blob)
    assert_redirected_to setup_two_factor_authentication_path
  end

  test 'a password step pending MFA cannot retrieve a private attachment' do
    user = @application.user
    user.totp_credentials.create!(secret: ROTP::Base32.random_base32, nickname: 'Authenticator')
    post sign_in_path, params: { email: user.email, password: 'password1234' }
    assert_redirected_to verify_method_two_factor_authentication_path(type: 'totp')
    get rails_blob_path(@blob)
    assert_redirected_to sign_in_path
  end

  test 'representations authorize the original document before producing variants' do
    authenticate(create(:constituent))
    variation = ActiveStorage::Variation.encode(resize_to_limit: [10, 10])
    assert_no_difference ['ActiveStorage::VariantRecord.count', 'ActiveStorage::Blob.count'] do
      get rails_blob_representation_proxy_path(@blob.signed_id, variation, 'proof.png')
      assert_response :not_found
    end

    authenticate(@application.user)
    variant, generated = prepared_variant
    get rails_representation_path(variant)
    assert_response :success
    assert_equal 'image/png', response.media_type
    assert_private_response

    get rails_blob_path(generated)
    assert_response :not_found
  end

  test 'redirect legacy and disk download routes are not mounted' do
    authenticate(@application.user)
    %w[/blobs/redirect /blobs /disk].each do |path|
      get "/rails/active_storage#{path}/#{@blob.signed_id}/proof.png"
      assert_response :not_found
    end
  end

  test 'unattached and unknown slots are denied even to administrators' do
    authenticate(create(:admin))
    unattached = ActiveStorage::Blob.create_and_upload!(io: StringIO.new('staged'), filename: 'staged.pdf', content_type: 'application/pdf')
    get rails_blob_path(unattached)
    assert_response :not_found

    ActiveStorage::Attachment.create!(record: @application, name: 'unregistered_document', blob: unattached)
    get rails_blob_path(unattached)
    assert_response :not_found
  end

  test 'shared bytes cannot gain a public audience or another owners permission' do
    @application.id_proof.attach(io: file_fixture('sample.pdf').open, filename: 'proof.pdf', content_type: 'application/pdf')
    private_pdf = @application.id_proof.blob
    mark_document_clean!(private_pdf, user: @application.user, slot: 'id_proof')
    guidance = build(:product_resource, url: nil)
    guidance.document.attach(private_pdf)
    guidance.save!
    get rails_blob_path(private_pdf)
    assert_redirected_to sign_in_path

    authenticate(@application.user)
    get rails_blob_path(private_pdf)
    assert_response :not_found
  end

  test 'a blob shared across two private owners must meet both owners access rules' do
    other_application = create(:application, :draft)
    other_application.residency_proof.attach(@blob)
    authenticate(@application.user)
    get rails_blob_path(@blob)
    assert_response :not_found

    authenticate(create(:admin))
    get rails_blob_path(@blob)
    assert_response :success
  end

  test 'malformed and expired signed references return private failures' do
    authenticate(@application.user)
    ['invalid-signature', @blob.signed_id(expires_in: -1.second)].each do |signed_id|
      get rails_service_blob_proxy_path(signed_id, @blob.filename)
      assert_response :not_found
      assert_private_response
    end
  end

  test 'missing stored bytes return an empty private failure without the files content length' do
    authenticate(@application.user)
    @blob.service.delete(@blob.key)
    get rails_blob_path(@blob)
    assert_response :not_found
    assert_empty response.body
    assert_private_response
    assert_equal 0, response.headers['Content-Length'].to_i
  end

  test 'missing generated bytes also retain no-store on representation failures' do
    authenticate(@application.user)
    variant, generated = prepared_variant
    generated.service.delete(generated.key)
    get rails_representation_path(variant)
    assert_response :not_found
    assert_empty response.body
    assert_private_response
  end

  test 'published product guidance remains public while blank medical forms keep their own route' do
    guidance = build(:product_resource, url: nil)
    guidance.document.attach(io: file_fixture('sample.pdf').open, filename: 'guide.pdf', content_type: 'application/pdf')
    guidance.save!
    mark_document_clean!(guidance.document.blob, purpose: :product_resource, slot: 'document')
    get rails_blob_path(guidance.document, disposition: 'attachment')
    assert_response :success
    assert_equal guidance.document.download, response.body
    assert_includes response.headers['Content-Disposition'], 'attachment'

    DocumentScan.find_by!(blob_id: guidance.document.blob.id).update!(status: :blocked)
    get rails_blob_path(guidance.document)
    assert_response :not_found
    assert_empty response.body

    get medical_certification_form_path
    assert_response :success
    assert_equal 'application/pdf', response.media_type
  end

  test 'W9s retain their dedicated current and archive authority' do
    vendor = create(:vendor, :with_w9)
    authenticate(vendor)
    blob = vendor.w9_form.blob
    mark_document_clean!(blob, user: vendor, purpose: :w9, slot: 'w9_form')
    get rails_blob_path(blob)
    assert_response :not_found
    get vendor_w9_document_path(vendor, blob)
    assert_response :success
    assert_private_response

    authenticate(create(:vendor))
    get vendor_w9_document_path(vendor, blob)
    assert_response :not_found
  end

  test 'retired direct upload allocation and disk PUT routes remain unavailable' do
    assert_no_difference 'ActiveStorage::Blob.count' do
      post '/rails/active_storage/direct_uploads', params: { blob: { filename: 'pending.pdf', byte_size: 10 } }, as: :json
    end
    assert_response :not_found
    put '/rails/active_storage/disk/upload-token', params: 'unscanned bytes', headers: { 'Content-Type' => 'application/pdf' }
    assert_response :not_found
  end

  private

  def prepared_variant
    variant = @blob.variant(resize_to_limit: [10, 10])
    generated = ActiveStorage::Blob.create_and_upload!(io: file_fixture('sample.png').open,
                                                       filename: 'preview.png', content_type: 'image/png')
    record = @blob.variant_records.create!(variation_digest: variant.variation.digest)
    record.image.attach(generated)
    # Stand in for the external image processor; routing, stored bytes, and authorization remain real.
    ActiveStorage::VariantWithRecord.any_instance.stubs(:processed).returns(generated)
    [variant, generated]
  end

  def authenticate(user)
    reset!
    clear_test_identity
    @authenticated_user = nil
    @test_user_id = nil
    secret = ROTP::Base32.random_base32
    user.totp_credentials.create!(secret: secret, nickname: 'Authenticator') if user.admin? || user.vendor?
    post sign_in_path, params: { email: user.email, password: 'password1234' }
    if user.admin? || user.vendor?
      assert_redirected_to verify_method_two_factor_authentication_path(type: 'totp')
      post process_verification_two_factor_authentication_path(type: 'totp'), params: { code: ROTP::TOTP.new(secret).now }
    end
    assert cookies[:session_token].present?, 'The production sign-in flow must issue a session cookie'
  end

  def assert_private_response
    assert_includes response.headers['Cache-Control'], 'private'
    assert_includes response.headers['Cache-Control'], 'no-store'
    assert_not_includes response.headers['Cache-Control'], 'public'
  end
end
