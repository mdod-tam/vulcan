# frozen_string_literal: true

require 'test_helper'

class CleanupDocumentScansConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  include ConcurrencyTestHelper

  test 'storage failure surfaces after the blob and scan deletion commit' do
    user = create(:constituent)
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new(file_fixture('income_proof.pdf').binread), filename: 'income_proof.pdf', content_type: 'application/pdf'
    )
    DocumentScanFixtures.clear!(blob, user: user)
    scan_id = DocumentScan.find_by!(blob_id: blob.id).id
    blob.update!(created_at: 8.days.ago)

    blob.service.stub(:delete, ->(_key) { raise IOError, 'Storage unavailable' }) do
      assert_raises(IOError) { CleanupUnattachedUploadsJob.perform_now }
    end

    assert_not ActiveStorage::Blob.exists?(blob.id)
    assert_not DocumentScan.exists?(scan_id)
    assert blob.service.exist?(blob.key)
  ensure
    blob&.purge
    cleanup_duplicate_review_test_data!(user) if user
  end

  test 'cleanup cannot leave a late attachment without its scan clearance' do
    user = create(:constituent)
    application = create(:application, user: user)
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new(file_fixture('income_proof.pdf').binread), filename: 'income_proof.pdf', content_type: 'application/pdf'
    )
    DocumentScanFixtures.clear!(blob, user: user)
    scan_id = DocumentScan.find_by!(blob_id: blob.id).id
    blob.update!(created_at: 8.days.ago)
    DocumentScan.find(scan_id).update!(created_at: 8.days.ago)
    cleanup_committed = Queue.new
    release_cleanup = Queue.new
    paused = false
    subscriber = lambda do |*, payload|
      next unless Thread.current[:document_scan_cleanup_test] && !paused && payload[:sql] == 'COMMIT'

      paused = true
      cleanup_committed << true
      release_cleanup.pop
    end
    subscription = ActiveSupport::Notifications.subscribe('sql.active_record', subscriber)
    cleanup_thread = on_own_connection do
      Thread.current[:document_scan_cleanup_test] = true
      CleanupUnattachedUploadsJob.perform_now
    end
    wait_for_signal(cleanup_committed, thread: cleanup_thread)
    assert_not ActiveStorage::Blob.exists?(blob.id)
    assert_not DocumentScan.exists?(scan_id)
    assert blob.service.exist?(blob.key), 'Storage deletion must wait for the database commit callback'

    # Commit a retained upload reference at Active Storage's final attachment write.
    attach_error = attempt_attachment(application, blob)
    release_cleanup << true
    reap_thread(cleanup_thread, timeout: 10, suppress_errors: false)

    if application.reload.income_proof.attached?
      assert_nil attach_error
      assert DocumentScan.exists?(scan_id)
      assert DocumentScan.cleared?(application.income_proof.blob)
      assert_equal blob.download, application.income_proof.download
    else
      assert_kind_of ActiveRecord::InvalidForeignKey, attach_error
      assert_not ActiveStorage::Blob.exists?(blob.id)
      assert_not DocumentScan.exists?(scan_id)
      assert_not blob.service.exist?(blob.key)
    end
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
    release_cleanup << true if release_cleanup
    reap_thread(cleanup_thread, timeout: 10, suppress_errors: true) if cleanup_thread
    application&.destroy!
    blob&.purge
    cleanup_duplicate_review_test_data!(user) if user
  end

  private

  def attempt_attachment(application, blob)
    ActiveStorage::Attachment.create!(record: application, name: 'income_proof', blob: blob)
    nil
  rescue ActiveRecord::InvalidForeignKey => e
    e
  end
end
