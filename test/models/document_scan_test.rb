# frozen_string_literal: true

require 'test_helper'

class DocumentScanTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup { @user = create(:constituent) }

  test 'only a clean scan grants clearance and metadata cannot grant it' do
    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new('%PDF-1.4\nproof'), filename: 'proof.pdf')
    assert_not DocumentScan.cleared?(blob)
    blob.update!(metadata: { source: 'docuseal', scanned: true })
    assert_raises(DocumentScan::NotCleared) { DocumentScan.require_clean!(blob) }
    scan = DocumentScan.create!(blob: blob, user: @user, purpose: :proof, slot: 'income_proof', sha256: 'a' * 64)
    %w[pending blocked failed].each do |status|
      scan.update!(status: status)
      assert_not DocumentScan.cleared?(blob)
    end
    scan.update!(status: :clean)
    assert DocumentScan.cleared?(blob)
  end

  test 'staging keeps an immutable private snapshot unattached without scheduling analysis' do
    source = Rack::Test::UploadedFile.new(Rails.root.join('test/fixtures/files/income_proof.pdf'), 'application/pdf')
    scan = nil
    assert_no_enqueued_jobs(only: ActiveStorage::AnalyzeJob) do
      scan = DocumentScan.stage!(input: source, user: @user, purpose: :proof, slot: 'income_proof')
    end
    assert_not_equal source.original_filename, scan.blob.key
    original = scan.blob.download
    source.tempfile.rewind
    source.tempfile.write('rewritten')
    source.tempfile.truncate(9)
    source.tempfile.flush
    assert_equal original, scan.blob.download
    assert_equal Digest::SHA256.hexdigest(original), scan.sha256
    assert_empty scan.blob.attachments
    assert scan.pending?
  end

  test 'clean snapshots are accepted only for their owner and declared purpose' do
    upload = Rack::Test::UploadedFile.new(Rails.root.join('test/fixtures/files/income_proof.pdf'), 'application/pdf')
    blob = scanned_upload(upload, user: @user)
    application = create(:application, user: @user)
    assert_equal blob, UploadedDocument.resolve!(blob.signed_id, record: application, name: :income_proof, scan_owner: @user)
    assert_raises(UploadedDocument::Refused) do
      UploadedDocument.resolve!(blob, record: application, name: :income_proof, scan_owner: create(:constituent))
    end
    DocumentScan.find_by!(blob: blob).update!(purpose: :certification)
    assert_raises(UploadedDocument::Refused) do
      UploadedDocument.resolve!(blob, record: application, name: :income_proof, scan_owner: @user)
    end
  end

  test 'a queue failure preserves a pending snapshot for recovery' do
    upload = Rack::Test::UploadedFile.new(Rails.root.join('test/fixtures/files/income_proof.pdf'), 'application/pdf')
    DocumentScanJob.stubs(:perform_later).raises(StandardError, 'queue unavailable')
    assert_difference 'DocumentScan.count' do
      assert_raises(StandardError) { DocumentScan.stage!(input: upload, user: @user, purpose: :proof, slot: 'income_proof') }
    end
    scan = DocumentScan.where(user: @user).sole
    assert scan.pending?
    assert scan.blob.service.exist?(scan.blob.key)
    assert_empty scan.blob.attachments
    assert_not DocumentScan.cleared?(scan.blob)
    assert_includes DocumentScan.due_for_work, scan
    DocumentScanJob.unstub(:perform_later)
    assert_enqueued_with(job: DocumentScanJob, args: [scan.id]) { RecoverDocumentScansJob.perform_now }
  end

  test 'an unrelated uniqueness failure cannot return another uploaders scan without a dedup key' do
    file = Rack::Test::UploadedFile.new(file_fixture('income_proof.pdf'), 'application/pdf')
    other_user = create(:constituent)
    other = DocumentScan.stage!(input: file, user: other_user, purpose: :proof, slot: 'income_proof')
    other.update!(status: :clean, completed_at: Time.current)

    DocumentScan.stub(:create!, ->(**) { raise ActiveRecord::RecordNotUnique, 'Unrelated unique constraint' }) do
      assert_no_difference ['DocumentScan.count', 'ActiveStorage::Blob.count'] do
        assert_raises(ActiveRecord::RecordNotUnique) do
          DocumentScan.stage!(input: file, user: @user, purpose: :proof, slot: 'income_proof')
        end
      end
    end

    assert_equal other_user.id, other.reload.user_id
    assert other.blob.service.exist?(other.blob.key)
    assert_not_equal @user.id, other.user_id
  end

  test 'a generated storage key collision never deletes the existing uploads bytes' do
    file = Rack::Test::UploadedFile.new(file_fixture('income_proof.pdf'), 'application/pdf')
    other = DocumentScan.stage!(input: file, user: create(:constituent), purpose: :proof, slot: 'income_proof')
    other.update!(status: :clean, completed_at: Time.current)
    original_bytes = other.blob.download

    ActiveStorage::Blob.stub(:generate_unique_secure_token, other.blob.key) do
      assert_no_difference ['DocumentScan.count', 'ActiveStorage::Blob.count'] do
        assert_raises(ActiveRecord::RecordNotUnique) do
          DocumentScan.stage!(input: file, user: @user, purpose: :proof, slot: 'income_proof')
        end
      end
    end

    assert_equal original_bytes, other.blob.download
    assert other.reload.clean?
  end

  test 'resume dispatches ready scans to their pending or unfinished continuation job' do
    file = Rack::Test::UploadedFile.new(file_fixture('income_proof.pdf'), 'application/pdf')
    pending = DocumentScan.stage!(input: file, user: @user, purpose: :proof, slot: 'income_proof')
    assert_enqueued_with(job: DocumentScanJob, args: [pending.id]) { assert_same pending, pending.resume! }

    certification = Rack::Test::UploadedFile.new(file_fixture('medical_certification_valid.pdf'), 'application/pdf')
    terminal = DocumentScan.stage!(input: certification, purpose: :certification, slot: 'medical_certification', continuation: 'docuseal')
    %w[clean blocked failed].each do |status|
      terminal.update!(status: status)
      assert_enqueued_with(job: DocumentSigning::AcceptScannedDocumentJob, args: [terminal.id]) { assert_same terminal, terminal.resume! }
    end
    terminal.update!(continued_at: Time.current)
    assert_no_enqueued_jobs(only: DocumentSigning::AcceptScannedDocumentJob) { assert_same terminal, terminal.resume! }
    pending.dismiss!
    assert_no_enqueued_jobs(only: DocumentScanJob) { assert_same pending, pending.resume! }
  end

  test 'resume refuses an unfinished snapshot without queuing provider work' do
    file = Rack::Test::UploadedFile.new(file_fixture('income_proof.pdf'), 'application/pdf')
    scan = DocumentScan.stage!(input: file, user: @user, purpose: :proof, slot: 'income_proof')
    scan.update!(next_attempt_at: nil)

    assert_no_enqueued_jobs do
      assert_raises(DocumentScan::SnapshotNotReady) { scan.resume! }
    end
    assert scan.reload.pending?
    assert_nil scan.next_attempt_at
  end

  test 'client MIME and filename cannot pass the byte gate' do
    Tempfile.create(['payload', '.png']) do |file|
      file.write('unknown bytes' * 100)
      file.rewind
      upload = Rack::Test::UploadedFile.new(file.path, 'image/png', original_filename: 'proof.png')
      assert_raises(UploadedDocument::Refused) do
        DocumentScan.stage!(input: upload, user: @user, purpose: :proof, slot: 'income_proof')
      end
    end
  end

  test 'account and global allocation caps refuse new snapshots without leaking stored objects' do
    source = Rack::Test::UploadedFile.new(Rails.root.join('test/fixtures/files/income_proof.pdf'), 'application/pdf')
    DocumentScan.stage!(input: source, user: @user, purpose: :proof, slot: 'income_proof')
    stub_const(DocumentScans::Stager, :ACCOUNT_DAILY_LIMIT, 1) do
      assert_no_difference ['DocumentScan.count', 'ActiveStorage::Blob.count'] do
        assert_raises(DocumentScan::LimitExceeded) { DocumentScan.stage!(input: source, user: @user, purpose: :proof, slot: 'income_proof') }
      end
    end
    stub_const(DocumentScans::Stager, :GLOBAL_DAILY_LIMIT, 1) do
      assert_raises(DocumentScan::LimitExceeded) do
        DocumentScan.stage!(input: source, user: create(:constituent), purpose: :proof, slot: 'income_proof')
      end
    end
  end

  test 'deleting an uploader preserves the clearance of their accepted document' do
    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new('%PDF-1.4 document'), filename: 'document.pdf')
    mark_document_clean!(blob, user: @user)
    @user.destroy!
    assert_nil DocumentScan.find_by!(blob: blob).user_id
    assert DocumentScan.cleared?(blob)
  end
end
