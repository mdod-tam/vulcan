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

  test 'claiming work leaves HTTP pacing to the client' do
    freeze_time do
      DocumentScanProviderBudget.expects(:try_reserve!).never
      scan = new_scan
      work = scan.claim_work!
      scan.complete_work!(token: work.token, result: result_for(scan, status: 'pending'))
      assert scan.reload.pending?
      assert_equal 30.seconds.from_now, scan.next_attempt_at

      competing = new_scan
      assert_equal :submit, competing.claim_work!.action
      assert_nil scan.claim_work!
      travel 30.seconds
      poll = scan.claim_work!
      assert_equal :poll, poll.action
      assert_equal '0e25dd32-2f60-4cec-b449-1eca2fd48f00', poll.provider_scan_id
      scan.complete_work!(token: poll.token, result: result_for(scan))
      assert scan.reload.clean?
    end
  end

  test 'queue wait does not consume the provider resolution window' do
    freeze_time do
      scan = new_scan
      travel 2.hours
      scan.expire_unresolved!
      assert scan.reload.pending?
      work = scan.claim_work!
      assert work
      assert scan.begin_provider_work!(token: work.token)
      assert_equal Time.current, scan.reload.submitted_at
      scan.complete_work!(token: work.token, result: result_for(scan, status: 'pending'))
      travel 1.hour
      scan.expire_unresolved!
      assert scan.reload.failed?
      assert_equal 'scan_unresolved', scan.last_error_code
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

  test 'dismissal stops queued work and revokes a claimed worker before provider submission' do
    queued = new_scan
    queued.dismiss!
    assert queued.reload.dismissed_at
    assert queued.failed?
    assert_equal 'scan_canceled', queued.last_error_code
    assert_not_includes DocumentScan.due_for_work, queued
    assert_nil queued.claim_work!

    claimed = new_scan
    work = claimed.claim_work!
    DocumentScan.find(claimed.id).dismiss!
    assert_not claimed.begin_provider_work!(token: work.token)
    assert_not claimed.complete_work!(token: work.token, result: result_for(claimed))
    assert_not claimed.fail_work!(token: work.token, code: 'transport_error', retryable: true)
    assert claimed.reload.failed?
    assert_nil claimed.submitted_at
    assert_nil claimed.lease_token
    assert_nil claimed.next_attempt_at
    assert_not DocumentScan.cleared?(claimed.blob)
  end

  test 'dismissal after a provider attempt keeps its cost history and rejects a late verdict' do
    scan = new_scan
    work = scan.claim_work!
    assert scan.begin_provider_work!(token: work.token)
    started_at = scan.reload.submitted_at
    assert started_at
    DocumentScan.find(scan.id).dismiss!
    assert_not scan.complete_work!(token: work.token, result: result_for(scan))
    assert_not scan.begin_provider_work!(token: work.token)
    assert_nil scan.claim_work!
    assert_equal started_at, scan.reload.submitted_at
    assert_equal 1, scan.attempts
    assert_not DocumentScan.cleared?(scan.blob)
  end

  test 'an expired lease cannot start a provider request or record its cancellation as a verdict' do
    freeze_time do
      scan = new_scan
      work = scan.claim_work!
      travel DocumentScan::Work::LEASE_DURATION
      assert_not scan.begin_provider_work!(token: work.token)
      assert_not scan.fail_work!(token: work.token, code: 'scan_canceled', retryable: false)
      assert_not scan.complete_work!(token: work.token, result: result_for(scan))
      assert scan.reload.pending?
      assert_nil scan.submitted_at
      assert_includes DocumentScan.due_for_work, scan
    end
  end

  test 'dismissing an accepted clean file does not revoke its clearance' do
    scan = new_scan(status: :clean)
    application = create(:application, user: @user)
    application.income_proof.attach(scan.blob)
    scan.dismiss!
    assert scan.reload.clean?
    assert DocumentScan.cleared?(scan.blob)
    assert_equal scan.blob, UploadedDocument.resolve!(scan.blob.signed_id, record: application, name: :income_proof, scan_owner: @user)
    assert_nil scan.claim_work!
  end

  test 'a receipt obtained before removal cannot accept the dismissed snapshot' do
    scan = new_scan(status: :clean)
    receipt = scan.blob.signed_id
    application = create(:application, user: @user)
    scan.dismiss!

    assert_raises(UploadedDocument::Refused) do
      UploadedDocument.resolve!(receipt, record: application, name: :income_proof, scan_owner: @user)
    end
    assert_not application.reload.income_proof.attached?
  end

  private

  def new_scan(**attributes)
    bytes = file_fixture('income_proof.pdf').binread
    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(bytes), filename: 'proof.pdf', content_type: 'application/pdf')
    DocumentScan.create!(blob: blob, user: @user, purpose: 'proof', slot: 'income_proof', sha256: Digest::SHA256.hexdigest(bytes),
                         next_attempt_at: Time.current, **attributes)
  end

  def result_for(scan, status: 'ok', sha256: scan.sha256)
    AttachmentScanner::Client::Result.new(status: status, scan_id: '0e25dd32-2f60-4cec-b449-1eca2fd48f00', sha256: sha256, byte_size: scan.blob.byte_size)
  end
end
