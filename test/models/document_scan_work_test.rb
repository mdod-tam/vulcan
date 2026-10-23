# frozen_string_literal: true

require 'test_helper'

class DocumentScanWorkTest < ActiveSupport::TestCase
  setup do
    @user = create(:constituent)
  end

  test 'only a matching clean result releases the immutable snapshot and duplicate work is inert' do
    scan = new_scan
    work = scan.claim_work!

    assert work
    assert_nil DocumentScan.find(scan.id).claim_work!
    assert scan.complete_work!(token: work.token, result: result_for(scan))
    assert scan.reload.clean?
    assert DocumentScan.cleared?(scan.blob)
    assert_nil scan.claim_work!
    assert_not scan.complete_work!(token: work.token, result: result_for(scan, status: 'found'))
    assert scan.reload.clean?
  end

  test 'provider failures and mismatched clean identity leave the upload unavailable' do
    freeze_time do
      %w[found warning failed unexpected].each do |status|
        scan = new_scan
        work = scan.claim_work!
        scan.complete_work!(token: work.token, result: result_for(scan, status: status))
        assert_not scan.reload.clean?
        assert_not DocumentScan.cleared?(scan.blob)
        travel DocumentScanProviderBudget::INTERVAL
      end
      scan = new_scan
      work = scan.claim_work!
      scan.complete_work!(token: work.token, result: result_for(scan, sha256: 'b' * 64))
      assert scan.reload.failed?
      assert_equal 'scan_content_mismatch', scan.last_error_code
      assert_not DocumentScan.cleared?(scan.blob)
    end
  end

  test 'submission and polling share the same paced provider budget' do
    freeze_time do
      scan = new_scan
      work = scan.claim_work!
      scan.complete_work!(token: work.token, result: result_for(scan, status: 'pending'))
      assert scan.reload.pending?
      assert_equal 30.seconds.from_now, scan.next_attempt_at

      competing = new_scan
      assert_nil competing.claim_work!
      assert_equal Time.current + DocumentScanProviderBudget::INTERVAL, competing.reload.next_attempt_at
      assert_nil competing.claim_work!
      travel DocumentScanProviderBudget::INTERVAL
      assert_equal :submit, competing.claim_work!.action
      travel 30.seconds - DocumentScanProviderBudget::INTERVAL
      assert_nil scan.claim_work!
      travel DocumentScanProviderBudget::INTERVAL - (30.seconds - DocumentScanProviderBudget::INTERVAL)
      poll = scan.claim_work!
      assert_equal :poll, poll.action
      assert_equal '0e25dd32-2f60-4cec-b449-1eca2fd48f00', poll.provider_scan_id
      scan.complete_work!(token: poll.token, result: result_for(scan))
      assert scan.reload.clean?
    end
  end

  test 'an expired worker lease cannot complete a later worker attempt' do
    freeze_time do
      scan = new_scan
      first = scan.claim_work!
      travel 5.minutes
      assert_includes DocumentScan.due_for_work, scan
      second = scan.claim_work!
      assert_not_equal first.token, second.token
      assert_not scan.complete_work!(token: first.token, result: result_for(scan))
      assert scan.reload.pending?
      assert scan.complete_work!(token: second.token, result: result_for(scan, status: 'warning'))
      assert scan.reload.blocked?
    end
  end

  test 'unready snapshots wait for storage and abandoned uploads fail closed' do
    freeze_time do
      scan = new_scan(next_attempt_at: nil)
      assert_nil scan.claim_work!
      assert_equal 0, scan.reload.attempts
      assert_not_includes DocumentScan.due_for_work, scan
      travel 1.hour
      scan.expire_unresolved!
      assert scan.reload.failed?
      assert_equal 'scan_unresolved', scan.last_error_code
      assert_not DocumentScan.cleared?(scan.blob)
    end
  end

  private

  def new_scan(**attributes)
    bytes = 'immutable scanned bytes'
    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(bytes), filename: 'proof.pdf', content_type: 'application/pdf')
    DocumentScan.create!(blob: blob, user: @user, purpose: 'proof', slot: 'income_proof', sha256: Digest::SHA256.hexdigest(bytes),
                         next_attempt_at: Time.current, **attributes)
  end

  def result_for(scan, status: 'ok', sha256: scan.sha256)
    AttachmentScanner::Client::Result.new(status: status, scan_id: '0e25dd32-2f60-4cec-b449-1eca2fd48f00', sha256: sha256, byte_size: scan.blob.byte_size)
  end
end
