# frozen_string_literal: true

require 'test_helper'

class DocumentScanCancellationConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  include ConcurrencyTestHelper

  test 'a worker waiting for the cancellation lock cannot claim provider work' do
    user = create(:constituent)
    bytes = 'private canceled snapshot'
    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(bytes), filename: 'proof.pdf', content_type: 'application/pdf')
    scan = DocumentScan.create!(blob: blob, user: user, purpose: 'proof', slot: 'income_proof',
                                sha256: Digest::SHA256.hexdigest(bytes), next_attempt_at: Time.current)
    worker_pid = Queue.new
    claimed = Queue.new
    cancel_pid = backend_pid
    worker = nil

    scan.with_lock do
      worker = on_own_connection do
        worker_pid << backend_pid
        claimed << DocumentScan.find(scan.id).claim_work!
      end
      pid = wait_for_signal(worker_pid, thread: worker)
      wait_until_blocked_on_lock(pid, blocked_by: cancel_pid, thread: worker)
      scan.dismiss!
    end
    reap_thread(worker, timeout: 10, suppress_errors: false)

    assert_nil claimed.pop
    assert scan.reload.failed?
    assert_nil scan.submitted_at
    assert_equal 0, scan.attempts
    assert_nil scan.lease_token
    assert_nil scan.next_attempt_at
  ensure
    reap_thread(worker, timeout: 10, suppress_errors: true) if worker
    blob&.purge
    cleanup_duplicate_review_test_data!(user) if user
  end
end
