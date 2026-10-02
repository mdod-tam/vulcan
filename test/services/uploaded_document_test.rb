# frozen_string_literal: true

require 'test_helper'

class UploadedDocumentTest < ActiveSupport::TestCase
  setup do
    @application = create(:application)
    @max = ProofUploadFormats::PROOF_MAX_BYTES
  end

  teardown do
    @tempfiles&.each(&:close!)
  end

  test 'stores a multipart upload at exactly the limit' do
    blob = resolve(pdf_upload(@max))

    assert_predicate blob, :persisted?
    assert_equal @max, blob.byte_size
  end

  test 'refuses a multipart upload one byte over the limit before storing it' do
    assert_no_difference 'ActiveStorage::Blob.count' do
      assert_refused(:too_large) { resolve(pdf_upload(@max + 1)) }
    end
  end

  test 'refuses a multipart upload whose content is a disallowed type before storing it' do
    upload = pdf_upload(2.kilobytes, content_type: 'text/plain', filename: 'notes.txt', bytes: 'plain notes ' * 200)

    assert_no_difference 'ActiveStorage::Blob.count' do
      assert_refused(:invalid_type) { resolve(upload) }
    end
  end

  test 'refuses blank and unsupported input' do
    assert_refused(:missing) { resolve(nil) }
    assert_refused(:missing) { resolve('') }
    assert_refused(:unsupported) { resolve(42) }
  end

  test 'resolves a signed ID for a recent unattached blob' do
    blob = stored_blob(3.kilobytes)

    assert_equal blob, resolve(blob.signed_id)
  end

  test 'refuses a signed ID when the caller accepts only uploads' do
    assert_refused(:unsupported) { resolve(stored_blob(3.kilobytes).signed_id, signed_ids: false) }
  end

  test 'refuses a malformed or purged signed ID' do
    assert_refused(:unavailable) { resolve('not-a-signed-id') }

    blob = stored_blob(3.kilobytes)
    signed_id = blob.signed_id
    blob.purge
    assert_refused(:unavailable) { resolve(signed_id) }
  end

  test 'refuses a blob whose stored file is missing' do
    blob = stored_blob(3.kilobytes)
    blob.service.delete(blob.key)

    assert_refused(:unavailable) { resolve(blob.signed_id) }
  end

  test 'refuses an unattached blob at the cleanup retention age' do
    blob = stored_blob(3.kilobytes)
    blob.update_column(:created_at, CleanupUnattachedUploadsJob::RETENTION.ago)

    assert_refused(:expired) { resolve(blob.signed_id) }
  end

  test 'refuses a blob attached to another application but reuses one in this same slot' do
    other = create(:application)
    elsewhere = stored_blob(3.kilobytes)
    other.income_proof.attach(elsewhere)
    assert_refused(:attached_elsewhere) { resolve(elsewhere.signed_id) }

    own = stored_blob(3.kilobytes)
    @application.income_proof.attach(own)
    assert_equal own, resolve(own.signed_id)
    assert_refused(:attached_elsewhere) { resolve(own.signed_id, name: 'residency_proof') }
  end

  test 'judges a direct upload by its identified type, not the type the browser declared' do
    bytes = "MZ\x90\x00#{'x' * 2048}"
    disguised = ActiveStorage::Blob.create_before_direct_upload!(
      filename: 'proof.pdf', byte_size: bytes.bytesize, content_type: 'application/pdf',
      checksum: OpenSSL::Digest::MD5.base64digest(bytes)
    )
    disguised.upload_without_unfurling(StringIO.new(bytes))
    assert_not_predicate disguised, :identified?

    assert_refused(:invalid_type) { resolve(disguised.signed_id) }
  end

  test 'accepts a TIFF scan' do
    tiff = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("II*\x00#{'x' * 2048}"), filename: 'scan.tif',
                                                  content_type: 'image/tiff')

    assert_equal 'image/tiff', resolve(tiff.signed_id).content_type
  end

  test 'refuses an oversized blob reached by signed ID' do
    assert_refused(:too_large) { resolve(stored_blob(@max + 1).signed_id) }
  end

  test 'takes the size limit from the purpose the model declares for the slot' do
    assert_equal :proof, UploadedDocument.declared_purpose(@application, 'income_proof')
    assert_equal :certification, UploadedDocument.declared_purpose(Application, 'medical_certification')
    assert_equal :w9, UploadedDocument.declared_purpose(Users::Vendor, 'w9_form')
    assert_raises(ArgumentError) { UploadedDocument.declared_purpose(PrintQueueItem, 'pdf_letter') }
  end

  test 'restorable returns a still-usable upload and writes nothing' do
    usable = stored_blob(3.kilobytes)
    expired = stored_blob(3.kilobytes)
    expired.update_column(:created_at, CleanupUnattachedUploadsJob::RETENTION.ago)
    elsewhere = stored_blob(3.kilobytes)
    create(:application).income_proof.attach(elsewhere)
    missing = stored_blob(3.kilobytes)
    missing.service.delete(missing.key)

    assert_no_changes -> { usable.reload.attributes } do
      assert_equal usable, UploadedDocument.restorable(usable.signed_id, record: nil, name: 'income_proof')
    end
    [expired, elsewhere, missing].each do |blob|
      assert_nil UploadedDocument.restorable(blob.signed_id, record: nil, name: 'income_proof')
    end
    assert_nil UploadedDocument.restorable('not-a-signed-id', record: nil, name: 'income_proof')
    assert_nil UploadedDocument.restorable(nil, record: nil, name: 'income_proof')
  end

  private

  def resolve(input, name: 'income_proof', signed_ids: true)
    UploadedDocument.resolve!(input, record: @application, name: name, signed_ids: signed_ids)
  end

  def assert_refused(reason, &)
    error = assert_raises(UploadedDocument::Refused, &)
    assert_equal reason, error.reason
  end

  def pdf_bytes(size)
    header = "%PDF-1.4\n"
    header + ('x' * (size - header.bytesize))
  end

  def pdf_upload(size, content_type: 'application/pdf', filename: 'proof.pdf', bytes: nil)
    tempfile = Tempfile.new(['proof', File.extname(filename)])
    tempfile.binmode
    tempfile.write(bytes || pdf_bytes(size))
    tempfile.rewind
    (@tempfiles ||= []) << tempfile
    ActionDispatch::Http::UploadedFile.new(tempfile: tempfile, filename: filename, type: content_type)
  end

  def stored_blob(size)
    ActiveStorage::Blob.create_and_upload!(io: StringIO.new(pdf_bytes(size)), filename: 'proof.pdf',
                                           content_type: 'application/pdf')
  end
end
